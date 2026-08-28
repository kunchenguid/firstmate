# Herdr lab setup for upstream sync

This is the one place the sync worker learns how the isolated Herdr lab works, so nobody re-discovers it mid-sync.
`bin/fm-herdr-lab.sh` and its `--help` own the exact commands and refusals; `docs/herdr-backend.md` "Destructive lab safety" owns the safety rationale.

## When the lab is required

- Every `monthly` tier, because `bin/fm-test-run.sh --all --fail-on-gate-skip 'herdr not found'` includes the `real-herdr-gated` family and refuses to skip it.
- A `weekly` tier whose kept diff selects the `real-herdr-gated` family, which `bin/fm-test-run.sh`'s changed-file-to-test map decides, not a hand-written path list.
  The skill's step 10 owns that check and the status guards it needs; a bare `comm` over two process substitutions reports a clean verdict when either listing fails, so do not re-derive it here.
- Never otherwise; a weekly sync that does not touch Herdr runs `--exclude-family real-herdr-gated` and needs no lab.

## What the brief must carry

The brief must be scaffolded with `bin/fm-brief.sh ... --herdr-lab` whenever the lab is required.
That flag emits the hard isolation contract naming `HERDR_LAB_HELPER` and the session name; a brief without it carries a loud `NOT ENABLED` declaration, and a worker must never add lab commands to such a brief by hand.
If the need appears only after dispatch, the worker stops with a `blocked:` line and Firstmate regenerates the brief; on the regenerated brief the worker runs the family from the skill's step 10 rather than blocking again.

## Preconditions

- `herdr`, `jq`, `treehouse`, and `python3` on `PATH`, because each one guards a whole suite at its head with `exit 0` and a missing binary is a skip, not a failure.
  `tmux` is not on this list: its only checks are per-case `return 0` skips inside `tests/fm-afk-launch.test.sh`, so its absence never turns a suite green by skipping it.
- `$HERDR_LAB_HELPER` executable, defaulting to `bin/fm-herdr-lab.sh`, because `tests/fm-backend-herdr-presentation-e2e.test.sh` and `tests/fm-herdr-session-cleanup-e2e.test.sh` in the family head-gate on `[ -x "$HERDR_LAB_HELPER" ]` and skip the whole suite otherwise.
  A monthly `--all` run adds a third such suite, `tests/fm-backend-herdr-focus-flash-e2e.test.sh`, which the family listing does not carry because it is unclassified.
  A stale exported value pointing at a deleted tree, or a checkout copied without the executable bit, is the way this bites.
  `--fail-on-gate-skip` accepts one token only, so assert these with `command -v` before the run rather than relying on it.
- Exactly one running `default` Herdr session, because the helper snapshots it as the fleet-state tripwire before provisioning and requires it byte-identical after teardown.
  Check with `herdr session list --json | jq '.sessions[] | select(.default == true)'`.
- The worker is not inheriting a pane identity from a Herdr-hosted terminal that should place work elsewhere; `tests/herdr-test-safety.sh`'s `herdr_forget_inherited_pane` shows which variables the suites drop.

## The helper

`HERDR_LAB_HELPER` is the absolute path to `bin/fm-herdr-lab.sh`; the `--herdr-lab` brief section sets it.
Session names must begin with `fm-lab-` and can never be `default`; the helper refuses anything else.

| Action | Command | What it does |
| --- | --- | --- |
| name | `S=$("$HERDR_LAB_HELPER" name <label>)` | Sanitizes the label, caps it at 16 characters, and appends process and random suffixes so socket paths stay short. |
| prepare | `"$HERDR_LAB_HELPER" prepare "$S"` | Records the running default session as the tripwire without starting a server; provision calls it for you. |
| provision | `"$HERDR_LAB_HELPER" provision "$S"` | Records the tripwire, starts a named server, and waits up to 60 seconds for it to report running. |
| run | `"$HERDR_LAB_HELPER" run "$S" <herdr args...>` | Runs one task-level Herdr command with a trailing `--session "$S"`; refuses caller-supplied `--session`, leading options, and every server or session lifecycle subcommand. |
| stop | `"$HERDR_LAB_HELPER" stop "$S"` | Guarded mid-run session stop; re-checks refuse-default immediately before stopping. |
| teardown | `"$HERDR_LAB_HELPER" teardown "$S"` | Guarded stop and delete, then verifies the default session is byte-identical to the tripwire and removes the record. |

Install `trap '"$HERDR_LAB_HELPER" teardown "$S"' EXIT` before provisioning so an aborted run still cleans up.

## The tripwire

Provision writes `${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-<uid>}/<session>.fleet-state.json` holding `{name, default, running, socket_path}` of the one running default session.
Teardown and re-provision compare a fresh snapshot against it and refuse on any difference, printing `FLEET-STATE TRIPWIRE FAILED`.
A missing, stopped, or changed default session is a hard failure, never a warning to ignore: stop and report it.

## Running the Herdr test family

The `real-herdr-gated` suites provision their own `fm-lab-*` sessions through the helper; the worker does not provision one for them.

```sh
bin/fm-test-run.sh --family real-herdr-gated --fail-on-gate-skip 'herdr not found'
```

`--fail-on-gate-skip` turns a missing `herdr` binary into a failure instead of a silent skip, matching the required CI lane.

## Manual proof and teardown

Use this when a kept commit needs a hand check against a live Herdr, or to confirm the lab works before a monthly run.

```sh
HERDR_LAB_HELPER=$PWD/bin/fm-herdr-lab.sh
S=$("$HERDR_LAB_HELPER" name <task-id>)
trap '"$HERDR_LAB_HELPER" teardown "$S"' EXIT
"$HERDR_LAB_HELPER" provision "$S"
"$HERDR_LAB_HELPER" run "$S" status --json | jq '.server.running'   # true
"$HERDR_LAB_HELPER" teardown "$S"; trap - EXIT
herdr session list --json | jq -r '[.sessions[].name] | join(",")'  # the lab name is gone
```

Forbidden at all times: direct `herdr server stop`, `herdr session stop`, `herdr session delete`, any server-global operation, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.
Other `fm-lab-*` sessions in the list belong to other live workers or suites; never stop or delete one you did not create.
