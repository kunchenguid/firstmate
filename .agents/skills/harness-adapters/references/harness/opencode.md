# OpenCode

Verified on 2026-10-01 against OpenCode 2.0.21, after earlier 1.15.7 through 1.18.4 verification.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | `bin/fm-spawn.sh` always provisions the worker's busy-state plugin for an opencode spawn, but its shape is keyed to the detected major. On a detected major >= 2 it writes the OpenCode 2 plugin, which maps `session.execution.started` to busy and `session.execution.succeeded`/`interrupted`/`failed` to idle, latched to the worker's own session, and keeps the OpenCode 1 `session.status` busy/retry/idle names as legacy inputs. On 1.x, or an undetected/unparseable version that falls back to 1.x, it writes the pre-port plugin that maps `session.status` busy/retry/idle and `session.idle`, so OpenCode 1 keeps exactly the busy-state wiring it had before the OpenCode 2 port. |
| Exit command | Version-sensitive, keyed to the major `bin/fm-spawn.sh` detects and records as `opencode_version` in the task meta. On 2.x: Ctrl-C, sent as a raw key from an idle composer, which `../../../bin/fm-control.sh` delivers through the key plane rather than the typed-submit path. Verified 2026-10-01 on 2.0.21: a single Ctrl-C from an idle composer returns the pane to the shell. Typing `/exit` also exits but opens a slash-command completion popup, so the key-plane Ctrl-C avoids that popup interacting with submit verification. On 1.x (or an unrecorded/legacy task): the typed `/exit` command, which exits both lines. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | Version-sensitive, keyed to the detected major. OpenCode 2.0.21 has no interactive top-level `--model` (`opencode run --model` remains only on the non-interactive path), so Firstmate pins the interactive model through `OPENCODE_CONFIG_CONTENT` as global `model` plus `agent.build.model`. OpenCode 1.x still takes the interactive `--model` flag, so there Firstmate passes `--model` and does not write the 2.x global/build model pin. An undetected or unparseable version (opencode unresolvable, or `--version` without a parseable x.y.z) falls back to the 1.x shape, so only a parsed major >= 2 takes the 2.x pin. |
| Effort flag | None for Firstmate's interactive `opencode --prompt` launch; `opencode run` has model variant syntax, but that is not this path. The effort instead rides the launch's `OPENCODE_CONFIG_CONTENT` JSON as the `build` agent's `variant` keyed to the resolved model. It is emitted only when the resolved model's provider is known to expose that effort as a variant (`anthropic/*`: high, max; `openai/*`: low, medium, high, xhigh); with no model resolved, another provider, or an effort outside its family's list, the variant is omitted. On 2.x the global/build model pin remains even when the variant is omitted; on 1.x, where the model arrives via `--model`, omitting the variant leaves the permission-only config. |
| Model discovery | Run `opencode models` to list available provider/model identifiers; OpenCode 2.0.21 no longer accepts a provider positional argument. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 2.0.21 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The primary integration was verified on 2026-10-01 with OpenCode 2.0.21.
OpenCode 2 requires local plugins to export a default definition with an `id` and `setup` function; Firstmate's primary plugins install their active behavior from `setup(ctx)`.
`.opencode/plugins/fm-primary-turnend-guard.js` subscribes to `session.execution.succeeded` through `ctx.event.subscribe` and queues a follow-up with `ctx.session.prompt` when `../../../bin/fm-turnend-guard.sh` returns 2.
The port also keeps the legacy OpenCode 1 `server` export for older adapters.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `ctx.tool.hook("execute.before")`.
The Herdr backend needs no OpenCode-2-specific Firstmate plugin: `bin/backends/herdr.sh` still owns pane lifecycle and composer handling, while Herdr's installed `herdr.opencode` and `herdr.opencode.session-selection` plugins loaded beside the Firstmate plugins on 2.0.21.
