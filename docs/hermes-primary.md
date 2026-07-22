# Hermes as a firstmate primary

Date: 2026-07-23.
Hermes Agent version under test: v0.19.0 (2026.7.20), install method git, Python 3.11.15.

This document records how firstmate treats **Hermes Agent** as a *primary* session harness: detection, session lock, supervision wake, optional shell hooks, residual gaps, and the exact commands used to verify them.

It does **not** claim Hermes is a verified *crewmate spawn* adapter.
Crew dispatch still requires a verified spawn harness (`claude`, `codex`, `opencode`, `pi`, or `grok`) until a separate crew-spawn verification lands.
When the primary is Hermes, set `config/crew-harness` to a verified spawn adapter (for example `claude` or `codex`) so default crew resolution does not point at an unspawnable name.

## What is verified

| Surface | Status | Mechanism |
|---|---|---|
| Session lock holder | verified | `bin/fm-lock.sh` `HARNESS_RE` includes `hermes` |
| Own-harness detection | verified | `HERMES_SESSION_ID` env marker, then process ancestry (`hermes` / `*hermes*` under python) |
| Supervision recipe | verified (protocol) | `docs/supervision-protocols/hermes.md` — Hermes terminal background + `notify_on_complete` around `bin/fm-watch-arm.sh` |
| Pre-tool arm seatbelt | verified (transport) | Hermes shell hook `pre_tool_call` → `bin/fm-hermes-primary-hook.sh` → `bin/fm-arm-pretool-check.sh` |
| Continuity seatbelt | verified (transport) | same bridge calls `bin/fm-continuity-pretool-check.sh` |
| Session-start nudge | verified (transport) | Hermes `pre_llm_call` with `extra.is_first_turn` → `{"context": ...}` from `bin/fm-sessionstart-nudge.sh` |
| Turn-end force-continue | **not available** | Hermes has no general Claude/Codex Stop block; `pre_verify` only covers coding verify loops. Passive `post_llm_call` observer runs the shared predicate and records a durable, rate-limited `state/.hermes-turnend-alarm` marker on a blind end; it cannot force a same-session follow-up. |
| Crewmate spawn on hermes | **not verified** | out of scope for this primary pass |

## Install primary hooks

From the firstmate home (once per machine):

```sh
bin/fm-hermes-install-primary-hooks.sh
bin/fm-hermes-install-primary-hooks.sh --status
```

Then restart the Hermes CLI session.
On first fire Hermes asks for shell-hook consent unless launched with `--accept-hooks`, `HERMES_ACCEPT_HOOKS=1`, or `hooks_auto_accept: true` in `~/.hermes/config.yaml`.

The installer merges only firstmate-marked entries under `hooks:` and backs up the previous file to `config.yaml.bak-firstmate`.

## Env markers observed

Interactive Hermes tool children in this environment exported:

- `HERMES_SESSION_ID` (non-empty session id)
- `HERMES_INTERACTIVE=1`
- `HERMES_QUIET=1`
- `HERMES_YOLO_MODE=1`
- `HERMES_REAL_HOME`
- `HERMES_KANBAN_BOARD`

Detection prefers `HERMES_SESSION_ID` so a stray `HERMES_INTERACTIVE` export outside a live session cannot misclassify the tree.

## Empirical checks (2026-07-23, LINC NUC)

### Lock acquire under live Hermes ancestry

```sh
bin/fm-lock.sh
# lock acquired: harness pid <hermes-pid>
bin/fm-lock.sh status
# lock: held by live harness pid <hermes-pid>
ps -p <hermes-pid> -o comm,args
# hermes .../venv/bin/hermes
```

### Detection

```sh
bin/fm-harness.sh
# hermes   (with HERMES_SESSION_ID set in the tool child)
```

### Behavior tests

```sh
bash tests/fm-lock-harness.test.sh
bash tests/fm-hermes-primary.test.sh
```

### Supervision snippet selection

```sh
bin/fm-supervision-instructions.sh --harness hermes | head -5
# Mode: Hermes background-notify supervision.
```

### Shell-hook bridge dry run (synthetic payload)

```sh
printf '%s' '{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":{"command":"bin/fm-watch-arm.sh &"},"cwd":"'"$PWD"'","session_id":"t"}' \
  | bin/fm-hermes-primary-hook.sh pre_tool_call
# expects a decision=block JSON when run inside a firstmate-shaped root
```

## Residual gaps (honest)

1. **No same-session turn-end force-continue.** Claude/Codex can block Stop with exit 2; Hermes `post_llm_call` / `on_session_end` are observer-only. The observer records a durable, rate-limited `state/.hermes-turnend-alarm` marker when a turn ends blind, but cannot re-prompt the session. Fleet safety depends on the background-notify supervision cycle plus `bin/fm-guard.sh` pull alarms.
2. **Hooks are user-global.** Unlike `.claude/settings.json`, Hermes shell hooks live in `~/.hermes/config.yaml`. The bridge fails open outside firstmate-shaped homes, but install is a deliberate captain/machine step.
3. **Crew spawn on Hermes is not verified.** Keep `config/crew-harness` on a verified spawn adapter while the primary is Hermes.
4. **Busy-pane regex** still relies on the shared default set; Hermes TUI busy text was not re-fingerprinted as a crew target in this pass because spawn is out of scope.

## Promotion checklist (future)

- [ ] Verify interactive crew launch (`hermes --yolo` / brief positional) under tmux and herdr.
- [ ] Fingerprint busy/idle composer signatures for Hermes TUI.
- [ ] Interrupt / exit / resume facts for stuck-crew recovery.
- [ ] Close the turn-end force-continue gap if Hermes gains a general keep-going hook outside `pre_verify`.
