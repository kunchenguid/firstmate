# OpenCode

Verified on 2026-10-10 with OpenCode 2.0.26 for the V2 plugin port and primary integration; the earlier composer, busy-queue, and doorbell behavior was verified on 2026-06-11 across versions 1.15.7 through 1.17.6 and on 2026-07-20 using 1.18.4.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic execution lifecycle: `session.execution.started` and `session.retry.scheduled` are active, `session.execution.succeeded`/`failed`/`interrupted` are inactive, latched to the worker's own session and scoped to the plugin's own location. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | `--model <provider/model>`. |
| Effort flag | None for Firstmate's interactive `opencode --prompt` launch; `opencode run` has `--variant`, but that is not this path. The effort instead rides the launch's `OPENCODE_CONFIG_CONTENT` JSON as the `build` agent's `variant` keyed to the resolved model, the config schema's per-model reasoning-effort field verified on 1.18.32. It is emitted only when the resolved model's provider is known to expose that effort as a variant (`anthropic/*`: high, max; `openai/*`: low, medium, high, xhigh); with no model resolved, another provider, or an effort outside its family's list, the variant is omitted and the permission-only launch is unchanged. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |
| Plugin API | OpenCode 2 loads only a default-exported plugin definition with `id` and `setup(ctx)`; the V1 named-function shape no longer loads (verified live on 2.0.26). The five tracked primary plugins and the generated worker busy-state plugin are V2-only and are not loaded by OpenCode 1.x. |
| Plugin event scope | A plugin instance is loaded per location, but `ctx.event.subscribe()` carries the whole server event stream, including sessions created at other locations, while `ctx.tool.hook` fires only for the instance's own location (verified live on 2.0.26). The plugins scope events by session location (`../../../.opencode/plugins/lib/fm-session-scope.js` owns the rule). |

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

The primary integration was ported to the OpenCode 2 plugin API and verified live on 2026-10-10 with OpenCode 2.0.26.
`.opencode/plugins/fm-primary-turnend-guard.js` subscribes to the execution-terminal events (`session.execution.succeeded`/`failed`/`interrupted`); OpenCode 2 never emits the V1 `session.idle` event (it exists in the schema but nothing publishes it).
Throwing cannot block a turn end, so the primary adapter treats the event as passive and uses `ctx.session.prompt` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2; the typed follow-up was verified in a live 2.0.26 session.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, arms on the same execution-terminal events, wakes the session with `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
A live 2.0.26 TUI session armed the plugin's watcher child from the shared service (the primary lock records the service process, which the plugin's ownership check reads).
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `ctx.tool.hook("execute.before", ...)`, whose `event.tool` is the V2 `shell` tool; the pipeline and shell-syntax background denials were verified live.
The session-start nudge subscribes before any slow work so a session created while setup still runs is never missed, and delivers through `ctx.session.prompt` exactly once per session at its own location.
