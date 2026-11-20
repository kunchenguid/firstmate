# Antigravity CLI

Antigravity's `agy` TUI, verified end to end with agy 1.2.0+ on Linux through the Herdr backend.
Verified as a full Firstmate harness (Primary, Secondmate, and Crewmate/Scout).
`../../../../../docs/verification/agy.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, refused if absent; a Go-compiled single binary, so the live process name is exactly `agy` with `argv[0]=agy`. |
| Launch | `agy --prompt-interactive "<brief>" --model <id> --effort <level> --dangerously-skip-permissions`, with the resolved absolute binary; the brief auto-submits with no extra Enter. The spawn pre-registers the worktree in agy's trust store first, then waits for a busy turn (answering the folder-trust dialog if it renders anyway) before reporting success. |
| Busy state | Semantic busy wiring via `$WT/.agents/plugins/fm-crew-busy/` (`PreInvocation` marks busy, `Stop` marks idle); on Herdr the native `working` status classifies busy, and elsewhere the `agy-regex` rendered-tail fallback in `../../../../../bin/fm-busy-lib.sh` does. |
| Rendered tail | Busy status row carries `esc to cancel` on the left; the idle row shows `? for shortcuts` instead. The `Generating...` word beside the braille spinner is free-floating output and is not a signal. |
| Turn end | Worktree `Stop` hook touches `state/<id>.turn-ended` and transitions busy state to `idle`; completion also arrives through the worker status protocol and, on Herdr, the native return to `idle`. |
| Exit | `/quit`, one Enter; the process exits. |
| Interrupt | Single `Escape`, which prints the Interrupted row and leaves an idle composer with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--dangerously-skip-permissions` auto-approves tool calls for the run. |
| Marker | None; a live TUI carries no `AGY_*` or `ANTIGRAVITY_*` variable. |
| Resume | `--continue` and `--conversation` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>` with the bare catalog id from `agy models` (for example `gemini-3.8-flash-high`); `bin/fm-spawn.sh` refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable or hung listing launches unvalidated with a notice. |
| Effort | `--effort low\|medium\|high`; `xhigh` and `max` stay in task metadata under the record-and-omit contract. |
| Composer | Separated `─` pair whose first row leads with `>` (`> ` when empty, `> <draft>` when pending), optionally followed by a `─`-bounded `● [HH:MM:SS] <cmd> running` background-task tray above `? for shortcuts`; classified via the shared identity+structure conjunction (`empty` when idle/done, `pending` when text follows `>`, `unknown` when working or without identity). |

## Trust, and where the decision persists

Every task worktree is a path agy has never seen, so an unregistered launch stops on `Do you trust the contents of this project?` with the safe choice `Yes, I trust this folder` preselected, and an unanswered dialog sends the turn into agy's scratch directory instead of the worktree.
There is no launch flag that suppresses the dialog, but agy honours a `trustedWorkspaces` entry in the captain's own `~/.gemini/antigravity-cli/settings.json` written ahead of launch (verified live), so `../../../../../bin/fm-spawn.sh` pre-registers the worktree through `../../../../../bin/fm-agy-trust.sh` before launch, the claude shape: the helper refuses anything but a linked worktree of the spawning project, records both the logical pane path and its resolved form because agy compares the logical cwd, and preserves every other key in the store.
The post-launch readiness gate is the backstop: it answers a dialog that renders anyway with a single Enter, then requires a busy verdict (Herdr's native `working` status or the pinned `esc to cancel` row) before the spawn reports success, and on a path that was not pre-registered it never counts a busy verdict as ready until the dialog has been answered, because Herdr's native verdict can precede the dialog.
A pane whose brief cannot be confirmed to run in the worktree fails the spawn, records the failure in the task status, and closes the endpoint.
Never steer into a pane still showing the dialog; a spawn that reported success has already cleared it.

## Credential precondition

A verified agy worker ran under a signed-in Google account with no key export and no dialog.
The unauthenticated failure mode was not observed, so treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `agy`, never `*agy*`.
No environment marker is promoted: `AGENT=1` observed on a live TUI is an inherited launcher value, not an agy identity, and agy does not clear an inherited `CLAUDECODE` - but a structural agy ancestor now outranks that retained marker, which `../../../../../bin/fm-harness.sh` decides without depending on the spawn's own launch-boundary marker clearing.
agy is included in the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, allowing an agy session to hold a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms a per-task busy generation for agy workers and writes semantic lifecycle hooks into `$WT/.agents/plugins/fm-crew-busy/`.
The `PreInvocation` hook runs `bin/fm-busy-event.sh apply <state> <id> busy` to record the active turn and emits `{}`.
The `Stop` hook touches `state/<id>.turn-ended`, runs `bin/fm-busy-event.sh apply <state> <id> idle` to transition the task to idle, and emits `{"decision":"allow"}`.
Because the hooks live in `.agents/plugins/fm-crew-busy/`, any project-tracked `.agents/hooks.json` stays untouched and excluded from git tracking via `.git/info/exclude`.
On teardown (`../../../../../bin/fm-teardown.sh`) or relaunch (`../../../../../bin/fm-control-lib.sh`), `fm-crew-busy` is safely pruned while preserving any pre-existing hooks or worker files.
On Herdr, the native `working` and `idle` status acts as a verified backend authority, and `fm_busy_agy_tail_busy` (`esc to cancel`) provides a rendered-tail fallback.

## Primary and secondmate integration

Antigravity CLI loads `<workspace>/.agents/hooks.json` for hook lifecycle events, running each command from `.agents/` itself.
agy 1.4.9 reads every top-level key as a named hook spec (firstmate ships one, `firstmate`), with flat `SessionStart` and `Stop` handler lists and `PreToolUse` grouped under `matcher` and `hooks`; any other top-level key, such as a `version` field, silently disables the whole file (verified live).
A PreToolUse handler that prints nothing allows the call, while a printed object without a `decision` denies it, so the seatbelts print only on deny.
SessionStart executes `bin/fm-sessionstart-agy.sh` to inject the session-start digest into model context.
PreToolUse invokes `bin/fm-arm-pretool-check.sh --agy`, `bin/fm-cd-pretool-check.sh --agy`, and `bin/fm-subagent-pretool-check.sh --agy`.
Stop executes `bin/fm-turnend-guard-agy.sh`, which parks on a home-scoped watcher cycle through `bin/fm-watch-arm.sh` (or `bin/fm-supervision-host.sh park` on a home that runs the host) under the registered 28800s hook timeout and delivers actionable wake output; only an optional `FM_AGY_PARK_TIMEOUT` bound re-arms via `{"decision":"continue","reason":"..."}` with `[supervision-park]`, and `FM_AGY_TURNEND_LOOP_CEILING` (default 180) bounds hook-driven turns.
A bounded 3-block repair nag is enforced via `bin/fm-turnend-guard.sh --agy` before failing open with `{}`.
See `../../../../../docs/supervision-protocols/agy.md` for the complete supervision protocol.
