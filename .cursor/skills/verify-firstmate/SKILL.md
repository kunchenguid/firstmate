---
name: verify-firstmate
description: >-
  Verify Firstmate, the agent-distro captain chat plus bin/ operator surface.
  Use when launching an isolated Firstmate home, doctoring the per-home session
  lock and session-start digest, driving captain-facing flows (session start,
  /bearings, inbox, watcher, /ahoy), capturing evidence, or cleaning up a
  verification run.
---

# verify-firstmate

Firstmate is an agent distro, not a web app, not a long-running HTTP service, and not a product CLI the captain types as the primary UI.

The captain launches a supported harness inside the cloned repo and talks to Firstmate in that chat.

The operator and agent drive surface is the tracked `bin/` scripts, especially `bin/fm-session-start.sh`, `bin/fm-bearings-snapshot.sh`, `bin/fm-inbox.sh`, and `bin/fm-watch-arm.sh`.

Optional surfaces that this skill does not treat as primary: Slack, X/Discord Relay, the spoken voice relay, and the `/bearings lavish` HTML board.

There is no default listen port.

Two Firstmate homes can run side by side when each has its own `FM_HOME`.

One home cannot: `state/.lock` admits a single live harness.

Never drive the live code-root home of an already-running Firstmate session.

Use the helper in [Helpers](#helpers) to create a scratch home, then set `FM_HOME` to that path on every command.

## Launch

Captain-facing start (production home, after `gh auth login` and clone) is one of:

```sh
claude
grok --trust
pi
cursor-agent --trust
```

Grok needs `--trust` once per clone so project hooks load.

Cursor Agent CLI also needs `--trust`, or none of its project hooks load.

The harness session-open hook then runs `bin/fm-session-start.sh`.

Ready signal on stdout: a banner `SESSION START - <home>` and a lock line `lock acquired: harness pid <n>`.

The digest always exits 0; a lock refusal is a loud inline banner, not a nonzero exit.

Isolated verification launch (required on a machine that already holds a live Firstmate lock, including this checkout):

```sh
skill=".cursor/skills/verify-firstmate"
"$skill/scripts/verify-home.sh" init
eval "$("$skill/scripts/verify-home.sh" env)"
"$skill/scripts/verify-home.sh" launch
```

`init` prints `VERIFY_HOME`, `EVIDENCE`, and `VERIFY_RUN_ID`.

`env` exports `FM_HOME` to that scratch home.

`launch` runs `FM_HOME="$VERIFY_HOME" bin/fm-session-start.sh` with live-home overrides unset.

Ready signal is the same banner, now naming the scratch home, plus `state/.session-start-complete` written with the lock pid.

Expected diagnostics on a cloud VM or feature branch, not launch failures:

- `MISSING: <tool>` lines when treehouse, no-mistakes, or axi tools are absent.
- `TANGLE:` when the code root is not on its default branch.
- `NETWORK CHECKS` still `IN PROGRESS` until `bin/fm-startup-network.sh report` finishes for that home.

Do not install missing tools during verify unless the captain approved them in this session.

Do not treat TANGLE as a broken scratch home; the isolated `FM_HOME` is still the instance under test.

Teardown is [Cleanup](#cleanup), never a process-name kill.

## Doctor

Read-only check of the scratch home this run created:

```sh
skill=".cursor/skills/verify-firstmate"
"$skill/scripts/verify-home.sh" doctor
```

Doctor passes only when all of these hold:

- `VERIFY_HOME` exists and is not the code root.
- `FM_HOME="$VERIFY_HOME" bin/fm-lock.sh status` prints `lock: held by live harness pid <n>`.
- `$VERIFY_HOME/state/.session-start-complete` exists and contains that lock pid.
- Any startup-network or watcher pid it mentions comes from this home's own status or lock files.

Equivalent manual check:

```sh
eval "$(.cursor/skills/verify-firstmate/scripts/verify-home.sh env)"
test -d "$FM_HOME"
test "$FM_HOME" != "$(pwd)"
bin/fm-lock.sh status
test -f "$FM_HOME/state/.session-start-complete"
```

Auth for the primary surface is the harness session itself; there is no app login cookie.

`gh auth login` is required only for live GitHub work and for `--include-prs` bearings.

Default bearings is local-only and does not need GitHub.

## Drive

Prefer the shipped scripts over a second harness chat.

Stable handles are command names, stdout banners, `fm-bearings.v1` fields, inbox record ids, and watcher status lines.

Do not click coordinates.

Do not write the live home's `data/` or `state/`.

Feature recipes live under `features/`.

Drive one mapped feature per prove run.

For `/bearings` (the gather half the skill actually executes), the user path is: captain says `/bearings`, Firstmate runs the snapshot, then composes the four-section chat digest from that snapshot alone.

```sh
eval "$(.cursor/skills/verify-firstmate/scripts/verify-home.sh env)"
bin/fm-bearings-snapshot.sh --json
```

Observables:

- `schema` is `fm-bearings.v1`.
- `home` is the last two path components of `$FM_HOME` (for `/tmp/verify-firstmate-home-<id>` that is `tmp/verify-firstmate-home-<id>`).
- `prs` is `not_requested (run: /bearings include PRs)` when live PRs were not asked.
- Seeded in-flight work appears under `in_flight` only when `data/backlog.md` and matching `state/<id>.meta` both exist.

Do not pass `--include-prs` unless the captain asked to include PRs and `gh` auth is valid.

Chat composition of the four sections is agent judgment over that snapshot; the executable proof is the snapshot contract.

`/ahoy` is session-history-only after helm is taken and cannot be driven by a script.

Inbox and watcher recipes are in their feature files.

## Evidence

Default evidence directory is `/tmp/verify-firstmate-evidence/<run-id>/`, printed by `init` as `EVIDENCE`.

Override with `VERIFY_FIRSTMATE_EVIDENCE` before `init`.

Cleanup never deletes this directory.

Capture action and resulting state:

```sh
eval "$(.cursor/skills/verify-firstmate/scripts/verify-home.sh env)"
mkdir -p "$EVIDENCE"
bin/fm-lock.sh status > "$EVIDENCE/doctor-lock.txt"
cp "$FM_HOME/state/.session-start-complete" "$EVIDENCE/session-start-complete"
bin/fm-bearings-snapshot.sh --json > "$EVIDENCE/bearings.json"
bin/fm-bearings-snapshot.sh > "$EVIDENCE/bearings.toon"
```

If you launched through the helper, also copy the launch transcript you saved at `$EVIDENCE/session-start.txt`.

Proof standards:

- Use the real gather command `bin/fm-bearings-snapshot.sh`, not an internal setter and not a test-only endpoint.
- Keep the default local-only mode; it skips live PR discovery and says so on the `prs` field and in `omitted[]`.
- After a seeded in-flight item, confirm that item's id in `in_flight` and that `home` still names the scratch home.
- After cleanup, `test -f "$EVIDENCE/bearings.json"` must still succeed.

## Cleanup

Tear down only the scratch home and child pids this run recorded.

Never `pkill -f bin/fm-watch.sh` or kill by process name.

Never kill the harness pid in `state/.lock`; that is this agent.

```sh
.cursor/skills/verify-firstmate/scripts/verify-home.sh cleanup
```

Cleanup TERM-then-KILL only:

- `pid=` from `$VERIFY_HOME/state/.startup-network.status`
- `pid` from `$VERIFY_HOME/state/.watch.lock/pid` if this home armed a watcher

Then it deletes `$VERIFY_HOME` and the run record at `/tmp/verify-firstmate.run`.

It prints `cleanup: leaving evidence at <EVIDENCE>` and leaves that tree on disk.

If a drive step fails, run cleanup before the next iteration so ports and detached workers are not stranded.

There is no listen port to free.

## Helpers

`scripts/verify-home.sh` is executable.

```sh
.cursor/skills/verify-firstmate/scripts/verify-home.sh --help
.cursor/skills/verify-firstmate/scripts/verify-home.sh init
eval "$(.cursor/skills/verify-firstmate/scripts/verify-home.sh env)"
.cursor/skills/verify-firstmate/scripts/verify-home.sh launch
.cursor/skills/verify-firstmate/scripts/verify-home.sh doctor
.cursor/skills/verify-firstmate/scripts/verify-home.sh cleanup
```

`init` refuses if a previous scratch home is still recorded.

`doctor` and `launch` refuse if `VERIFY_HOME` is the code root.

`cleanup` refuses to delete the code-root home.
