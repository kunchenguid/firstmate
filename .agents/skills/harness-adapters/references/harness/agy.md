# Antigravity CLI

Antigravity's `agy` TUI, verified end to end on Linux through the Herdr and tmux backends.
Verified as a PRIMARY supervisor, SECONDMATE, and CREWMATE/SCOUT adapter.
`../../../../../docs/verification/agy.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, refused if absent; a Go-compiled single binary, so the live process name is exactly `agy` with `argv[0]=agy`. |
| Launch | `agy --prompt-interactive "<brief>" --model <id> --effort <level> --dangerously-skip-permissions`, with the resolved absolute binary; the brief auto-submits with no extra Enter. The spawn pre-registers the worktree in agy's trust store first, then waits for a busy turn (answering the folder-trust dialog if it renders anyway) before reporting success. |
| Busy state | Semantic busy wiring via `$WT/.agents/hooks.json` (`PreInvocation` marks busy, `Stop` marks idle); on Herdr the native `working` status classifies busy, and elsewhere the `agy-regex` rendered-tail fallback in `../../../../../bin/fm-busy-lib.sh` does. |
| Rendered tail | Busy status row carries `esc to cancel` on the left; the idle row shows `? for shortcuts` instead. The `Generating...` word beside the braille spinner is free-floating output and is not a signal. |
| Turn end | Worktree `Stop` hook touches `state/<id>.turn-ended` and transitions busy state to `idle`. Completion also arrives through the worker status protocol and, on Herdr, the native return to `idle`. |
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
`agy` is recognized in `../../../../../bin/fm-session-lock-lib.sh` so Antigravity CLI can hold the session lock when acting as supervisor.

## Worker busy state and turn end

`bin/fm-spawn.sh` arms a per-task busy generation for agy workers and writes semantic lifecycle hooks into `$WT/.agents/hooks.json`.
The `PreInvocation` hook runs `bin/fm-busy-event.sh apply <state> <id> busy` to record the active turn and emits `{}`.
The `Stop` hook touches `state/<id>.turn-ended`, runs `bin/fm-busy-event.sh apply <state> <id> idle` to transition the task to idle, and emits `{"decision":"allow"}`.
If the project worktree already contains `.agents/hooks.json`, `bin/fm-spawn.sh` merges `fm-crew-busy` into the existing configuration rather than overwriting it, and excludes `.agents/hooks.json` from git tracking.
On teardown (`bin/fm-teardown.sh`) or relaunch (`bin/fm-control-lib.sh`), `fm-crew-busy` is safely pruned while preserving any pre-existing hooks.
On Herdr, the native `working` and `idle` status acts as a verified backend authority, and `fm_busy_agy_tail_busy` (`esc to cancel`) provides a rendered-tail fallback.

## Secondmate integration

Supported as a persistent secondmate adapter.
`bin/fm-agy-trust.sh --secondmate-home <home> <id>` validates the secondmate home marker (`.fm-secondmate-home`) and pre-registers the home directory in `~/.gemini/antigravity-cli/settings.json` under `trustedWorkspaces`.
Secondmate homes supervise their fleets using the same background-notify supervision protocol and non-blocking `Stop`-hook backstop as the primary supervisor (`docs/supervision-protocols/agy.md`).

## Delegation tools and PreToolUse guard

Antigravity CLI exposes built-in in-process subagent tools (`invoke_subagent`, `define_subagent`, `send_message`, `manage_subagents`).
Firstmate must never use these for project delegation because in-process subagents bypass Treehouse worktrees, Herdr/tmux panes, and fleet supervision records.
Tracked `.agents/hooks.json` registers a `PreToolUse` hook running `bin/fm-subagent-pretool-check.sh`, which parses Antigravity's `.toolCall.name` payload and returns `{"decision":"deny","reason":"..."}` on stdout with exit 0 to block native subagent creation in primary homes.
In linked task worktrees, the shared primary-scope check keeps the guard inert so legitimate worker tools remain allowed.

## Primary integration

Supported via Antigravity's tracked background `run_command` tool (`WaitMsBeforeAsync: 1000`) and reactive wakeup, paired with the non-blocking `Stop` hook backstop registered in `.agents/hooks.json` running `bin/fm-turnend-guard-agy.sh` (`docs/supervision-protocols/agy.md`).
When fleet supervision is active, the primary session arms `bin/fm-watch-arm.sh` via `run_command` (`WaitMsBeforeAsync: 1000`) and receives actionable wakes out-of-band when the background task exits.
At turn end, `bin/fm-turnend-guard-agy.sh` returns `{"decision": "allow"}` immediately when a healthy watcher cycle is running, supervision is inactive, or the session is in away mode (`state/.afk`).
When unread wakes remain queued in `state/.wake-queue` or active tasks are in flight with no healthy watcher cycle, the hook returns `{"decision": "continue", "reason": "..."}` on stdout with exit 0 so the session drains or re-arms before stopping.
Consecutive hook continuations are bounded by `FM_AGY_TURNEND_LOOP_CEILING` (default 180), and missing-watcher repair continuations by `FM_AGY_TURNEND_BLOCK_BUDGET` (default 3) before failing open.
Shared turn-end guard logic is reached via `bin/fm-turnend-guard.sh --agy`.
