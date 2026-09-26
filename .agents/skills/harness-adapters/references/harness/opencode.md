# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4.
Permission precedence and composer rendering were checked on 2026-09-24 with 1.18.32.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | `--model <provider/model>`. |
| Effort flag | None for Firstmate's interactive `opencode --prompt` launch verified on 1.17.6; `opencode run` has `--variant`, but that is not this path. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |
| Crewmate permissions | `../../../bin/fm-spawn.sh` passes `OPENCODE_PERMISSION` with explicit allow rules for OpenCode 1.18 permission keys, including `edit` and `external_directory`; OpenCode applies that variable after project top-level permissions. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.
OpenCode 1.18.32 [merges `OPENCODE_PERMISSION` after loaded config](https://github.com/anomalyco/opencode/blob/v1.18.32/packages/opencode/src/config/config.ts#L2543-L2569), while [its permission schema](https://github.com/anomalyco/opencode/blob/v1.18.32/packages/core/src/v1/config/permission.ts#L318-L355) lists the supported named keys.
OpenCode 1.18.32 draws a shortcut row directly below its left-bar composer: `tab agents  ctrl+p commands` on the home screen, and `<cwd>  <tokens>  ctrl+p commands` in the session view where every fm-spawn worker idles after its `--prompt` turn.
The shared composer classifier recognizes that row and the muted idle hint when Herdr's bounded capture omits the composer's first row, so a live idle composer can be proved empty for exit and relaunch.
Bright typed text and unclaimed activity retain their refusing verdicts.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.
