# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4, and the model and config behavior re-verified on 2026-10-10 using 2.0.26.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The spawn-generated plugin reports semantic busy state; [`bin/fm-spawn.sh`](../../../../../bin/fm-spawn.sh) owns its step/execution tracking and session-scoping invariant. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | None on the interactive launch; [`opencode-model-launch.md`](../../../../../docs/verification/opencode-model-launch.md) owns the measured v2 flag compatibility. |
| Effort flag | None on the interactive launch; the supported config variants are `anthropic/*`: high, max, and `openai/*`: low, medium, high, xhigh. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Model and launch settings | Firstmate merges its model, `permission["*"] = "allow"`, and supported `agent.build.model` / `agent.build.variant` effort settings into valid untracked `.opencode/opencode.json`, preserving unrelated keys and existing file permissions. The merge leaves the operator's global config intact; never hand-edit `~/.config/opencode/opencode.jsonc` to configure a Firstmate launch. `OPENCODE_CONFIG_CONTENT` is not used for these settings. The `x-firstmate-model-pin` marker records managed values and displaced settings. A `default` model launch clears Firstmate's top-level and build-agent model pins, restores any model values they displaced, and retains permission, the effort variant, and unrelated settings; with no displaced model, it removes the corresponding key. A selected-model launch with unsupported or omitted effort restores any build model and variant displaced by Firstmate's previous effort override. Malformed JSON, invalid marker data, or externally changed managed values refuse the launch. A config path tracked in the git index refuses every OpenCode launch, including `default` and locally deleted files, without modifying that path. [`write_opencode_worktree_config` in `bin/fm-spawn.sh`](../../../../../bin/fm-spawn.sh) owns the merge mechanics and legacy-pin recognition. |
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

The primary integration was first verified on 2026-07-08 with OpenCode 1.17.6, and the plugin contract was re-verified on 2026-09-30 against OpenCode 2.0.20.
The OpenCode 2 plugin contract is owned by [`.opencode/plugins/lib/fm-opencode-contract.js`](../../../../../.opencode/plugins/lib/fm-opencode-contract.js), including turn-end detection, event scoping, tool naming, and root resolution.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for that turn end.
The turn end is passive and does not block `opencode run`, so the primary adapter uses `ctx.session.prompt` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from the `ctx.tool.hook("execute.before", ...)` callback, and matches the tool OpenCode 2 actually registers it as, `shell`, not `bash`.
