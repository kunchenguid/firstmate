# OpenCode

The current V2 native-server and deterministic verification is recorded in [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#opencode-v2-native-integration).
Earlier interactive behavior was verified across V1 versions 1.15.7 through 1.18.4.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's `session.execution` lifecycle: `started` is active, and the three terminal events `succeeded`, `failed`, and `interrupted` are inactive, latched to the worker's own session so a cancelled turn still clears busy. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Launch flag | `--standalone`, required for every Firstmate launch on 2.x: the default launch attaches to the shared `opencode serve --service` daemon, which hosts plugins with its own environment and PID and ignores `OPENCODE_CONFIG_CONTENT` after it starts. |
| Model selection | The `model` key in the per-launch `OPENCODE_CONFIG_CONTENT`; the full TUI command has no `--model` flag. |
| Effort flag | None; the per-launch `agents.build.model` reference carries the V2 variant after `#`, preserving the supported provider-effort mapping in `opencode_config_content()` in `../../../bin/fm-spawn.sh`. |
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

The native-server guard and supervision proof uses the real OpenCode V2 server with a loopback provider fixture; [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#opencode-v2-native-integration) owns its coverage and remaining TUI limits.
`.opencode/plugins/fm-primary-turnend-guard.js` uses the V2 plugin definition and subscribes to `session.execution.succeeded` and `session.execution.failed`.
OpenCode 2.x publishes no `session.idle` or `session.status` event; a plugin-boundary probe of a full turn on 2.0.11 observed the execution lifecycle instead, so those events are the turn boundary.
The primary adapter treats the event as passive and uses `ctx.session.prompt` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
Native V2 follow-up admission is verified; credentialed TUI rendering remains separate opt-in coverage.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

OpenCode 2.x hosts plugins in the server process, so a primary or crewmate launch must pass `--standalone`; a plugin hosted by the shared background service reads the daemon environment, walks the daemon PID for lock ownership, and shares one process-wide coordinator across every project it serves.
The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
It also re-arms on `session.execution.interrupted`, which the guard deliberately skips; `../../../docs/supervision-protocols/opencode.md` and `../../../docs/turnend-guard.md` own that interrupted-turn policy.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from the V2 `execute.before` tool hook.
