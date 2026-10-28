# OpenCode

Verified on 2026-10-01 against OpenCode 2.0.21, after earlier 1.15.7 through 1.18.4 verification, with composer furniture re-verified on 2026-09-18 using 1.18.31 and the mode-footer furniture re-verified on 2026-10-14 using 1.19.0.
On 2026-10-15 the dual-export primary plugins loaded once each and the turn-end guard fired once on 1.15.7, 1.18.20, and 1.18.31, and watcher continuity plus the 1.x worker launch and exit passed on 1.18.20 and 1.18.31, so the plugins do not need the 1.18.29 object entrypoint (evidence in `docs/verification/runtime-backends.md`).

## Operating facts

| Fact | Value |
|---|---|
| Busy state | `bin/fm-spawn.sh` always provisions the worker's busy-state plugin for an opencode spawn, but its shape is keyed to the detected major. On a detected major >= 2 it writes the OpenCode 2 plugin, which maps `session.execution.started` to busy and `session.execution.succeeded`/`interrupted`/`failed` to idle, latched to the worker's own session, and keeps the OpenCode 1 `session.status` busy/retry/idle names as legacy inputs. On 1.x, or an undetected/unparseable version that falls back to 1.x, it writes the pre-port plugin that maps `session.status` busy/retry/idle and `session.idle`, so OpenCode 1 keeps exactly the busy-state wiring it had before the OpenCode 2 port. |
| Exit command | Version-sensitive, keyed to the major `bin/fm-spawn.sh` detects and records as `opencode_version` in the task meta. On 2.x: raw keys, which `../../../bin/fm-control.sh` delivers through the key plane rather than the typed-submit path: Ctrl-U to clear the composer, then Ctrl-C, then one more Ctrl-C if the agent is still alive. A single Ctrl-C from an empty composer returns the pane to the shell, while a Ctrl-C over leftover composer text only clears it (verified on 2.0.11, 2.0.21, and 2.0.22; evidence in `docs/verification/runtime-backends.md`). Typing `/exit` also exits but opens a slash-command completion popup, so the key-plane Ctrl-C avoids that popup interacting with submit verification. On 1.x (or an unrecorded/legacy task): the typed `/exit` command, which exits both lines. Known limitation: on a wide pane with no provider connected, OpenCode 2.0.22 draws a `/connect` sidebar on the composer row, so `fm-control.sh` exit refuses safely as pending text; teaching the composer read to ignore that sidebar is follow-up work. |
| Launch and brief delivery | Version-sensitive, keyed to the detected major. On 2.x `bin/fm-spawn.sh` launches `opencode --standalone --prompt "<brief>"`: the default 2.x launch attaches to the shared background service, which hosts plugins with the service's own environment and ignores the pane's `OPENCODE_CONFIG_CONTENT`. OpenCode 2.0.11 leaves the `--prompt` brief unsent in the composer while 2.0.22 submits it, so after a 2.x launch the spawn waits for the worker's busy-state plugin to report the turn start, sends one Enter only when it has not started and the composer reads the brief as pending (an unreadable composer waits, getting its Enter only at a later deadline), and fails the spawn when the turn never starts. On 1.x or an undetected version the launch has no `--standalone` and no delivery gate. |
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

Since OpenCode 1.18.0 (upstream anomalyco/opencode#36457, merged 2026-07-11) the idle composer draws the pane's working directory and git branch right-aligned inside the composer rows above the Build footer, wrapped over up to three rail-width fragments whose final fragment continues onto the footer row's right end, whenever the pane has an active session and no higher-priority footer hint.
That cwd:branch indicator is composer furniture, never typed text, and the shared classifier in `../../../../../bin/fm-composer-lib.sh` (`_fm_composer_leftbar_cwd_start`) recognises it structurally by position and shape, for a cwd under `$HOME` (`~/...`) or an absolute cwd outside it, so an idle or busy pane still reads proven `empty`.
An earlier read treated those fragments as unsent typed input, which made every idle 1.18.x tmux worker unsteerable (observed live on 1.18.31) until the doorbell was typed by hand.
OpenCode 1.19.0 also draws the mode/model/branch footer row de-emphasised, with its mode word and middle-dot separators under `fm_composer_strip_ghost`'s luminance threshold, so that furniture is gone from the row the ghost-stripped read sees and the classifier proves it from the ANSI-stripped form of the row instead; the dated capture, the safe plain-form argument, and the regression pointers are in [runtime-backends.md](../../../../../docs/verification/runtime-backends.md).
Without a cursor anchor a full-pane capture of this version still defers as `unknown` because the status rail below the composer floor row is contiguous, non-blank content; that deferral is the strict posture, not a misclassification.

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
`.opencode/plugins/fm-primary-turnend-guard.js` subscribes to the terminal `session.execution.succeeded`, `session.execution.failed`, and `session.execution.interrupted` events through `ctx.event.subscribe` and queues a follow-up with `ctx.session.prompt` when `../../../bin/fm-turnend-guard.sh` returns 2.
The port also keeps the legacy OpenCode 1 `server` export for older adapters.
Each primary plugin carries both exports rather than being gated at load time, so OpenCode 1 runs the `server` export and OpenCode 2 runs `setup`.
Start an OpenCode 2 primary or secondmate home with `opencode --standalone` so its plugins run in the home's own process with its `FM_HOME` and session-lock ancestry, rather than in the shared background service; `bin/fm-spawn.sh` already does this for a `--secondmate` launch.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `ctx.tool.hook("execute.before")`.
The Herdr backend needs no OpenCode-2-specific Firstmate plugin: `bin/backends/herdr.sh` still owns pane lifecycle and composer handling, while Herdr's installed `herdr.opencode` and `herdr.opencode.session-selection` plugins loaded beside the Firstmate plugins on 2.0.21.
