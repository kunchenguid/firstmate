# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4.
The primary integration's plugins moved to OpenCode v2's plugin API and were re-verified 2026-09-27 against OpenCode 2.0.18; see "Primary integration" below for the minimum version this now requires.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic state derived from OpenCode v2's `session.execution.*` lifecycle: `started` is active and `succeeded`, `failed`, and `interrupted` are inactive, latched to the worker's own session; `session.status` and `session.idle` are deprecated in the v2 schema. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | None for Firstmate's interactive `opencode --prompt` launch on v2 - the interactive CLI has no `--model` (only the headless `opencode run` subcommand has `--model <provider/model>[#variant]`), and a flag passed to the interactive CLI is silently ignored. Firstmate carries the model in the launch's `OPENCODE_CONFIG_CONTENT` JSON instead. |
| Launch | Firstmate launches the OpenCode primary as `opencode --standalone --prompt ...`; `--standalone` runs a private server that inherits this launch's environment and PID, which plugin ownership and endpoint correlation depend on. |
| Effort flag | None for Firstmate's interactive `opencode --prompt` launch; `opencode run` has `--variant`, but that is not this path. The effort instead rides the launch's `OPENCODE_CONFIG_CONTENT` JSON as the `build` agent's `variant` keyed to the resolved model, the config schema's per-model reasoning-effort field verified on 1.18.32. It is emitted only when the resolved model's provider is known to expose that effort as a variant (`anthropic/*`: high, max; `openai/*`: low, medium, high, xhigh); with no model resolved, another provider, or an effort outside its family's list, the variant is omitted and the permission-only launch is unchanged. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

All five `.opencode/plugins/fm-primary-*.js` files export OpenCode v2's plugin shape, a bare `{ id, async setup(ctx) { ... } }` default export; OpenCode v2 rejects any other shape with "Plugin must export a default definition with an id and an effect or setup function.", which is exactly how the legacy V1 named-export shape (`export const FmPrimaryX = async ({ client, directory, worktree }) => ({ ... })`) failed on the installed 2.0.18.
These plugins therefore require OpenCode's v2 plugin API: the new minimum supported OpenCode for the primary integration is the v2 line (verified on 2.0.18), and they no longer load under any release whose loader only understands the V1 shape.
No dual V1/V2 compatibility entrypoint is implemented, because no real pre-v2 OpenCode install was available to verify one against.
The port was verified 2026-09-27 against OpenCode 2.0.18: `ctx.location.directory` names the project directory (the plugins resolve the git root from it via `git rev-parse --show-toplevel`, matching the old `directory`/`worktree` resolution now that v2 exposes only one location field); `ctx.event.subscribe({ signal })` returns an async iterable of `{ type, data }` events, so `session.created` and the turn-boundary `session.execution.*` events are read as `event.data.sessionID`; `ctx.tool.hook("execute.before", cb)` still blocks by throwing, but OpenCode v2 renamed its built-in shell-execution tool id from V1's `bash` to `shell`, which the pretool and cd-guard seatbelts now match; and `ctx.session.prompt({ sessionID, text, delivery: "queue" })` replaces V1's `client.session.promptAsync` for injecting a follow-up turn.
The turn boundary is the `session.execution.*` lifecycle - `started` marks a turn active and `succeeded`/`failed` end it, with `interrupted` where the watcher re-arms - because OpenCode v2 deprecated `session.idle` and `session.status` and its own app derives busy/idle from these events.

`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.execution.succeeded`, `.failed`, and `.interrupted`.
Throwing from those events does not block `opencode run`, so the primary adapter treats the terminal events as passive and uses `ctx.session.prompt` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `ctx.tool.hook("execute.before", ...)`.
