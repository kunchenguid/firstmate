# OpenCode

Harness behavior was verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4.
The worker busy-state lifecycle below describes the generated OpenCode 2 plugin.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The generated OpenCode 2 worker plugin uses `session.execution.started` as active and `session.execution.succeeded`, `.failed`, or `.interrupted` as inactive, latched to the worker's own session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Interactive task launch | Firstmate probes `opencode mini --help` for a `Usage: opencode mini` line; OpenCode v2 uses `opencode mini`, while legacy releases use the top-level command. Both receive the requested `--model <provider/model>` and worker brief through `--prompt`. |
| Effort flag | None for the interactive task launch; `opencode run` has `--variant`, but that is a different, non-interactive path. |
| Model discovery | Run `opencode models` with no argument to list every available `provider/model` identifier. The legacy `opencode models <provider>` form is rejected by OpenCode v2 ("Unexpected positional argument") and prints usage text rather than a catalog, so `../../../bin/fm-spawn.sh` reads the whole catalog and matches the exact id. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

## Free model selection

| Fact | Value |
|---|---|
| Current free catalog | OpenCode Zen listed Big Pickle (`big-pickle`), Space Bunny Free (`space-bunny-free`), LongCat 2.5 Preview Free (`longcat-2.5-preview-free`), MiMo-V2.6-Flash Free (`mimo-v2.6-flash-free`), MiMo-V2.5 Free (`mimo-v2.5-free`), Ling 3.0 Flash Fin Free (`ling-3.0-flash-fin-free`), Nemotron 3 Ultra Free (`nemotron-3-ultra-free`), Nemotron 3.5 Lightning Free (`nemotron-3.5-lightning-free`), Muse Spark 1.3 Contributor Free (`muse-spark-1.3-contributor-free`), and Jev 1.13 Free (`jev-1.13-free`) when checked on 2026-09-26. This promotional catalog can change; check the [current Zen catalog](https://opencode.ai/docs/zen/) and run `opencode models` at dispatch time. |
| Dispatch eligibility | See [crew dispatch configuration](../../../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) for the spawn-time availability and free-pricing checks. Free pricing does not guarantee data retention; see Data handling below. |
| Data handling | The Zen privacy policy says providers default to zero retention and no model training, with listed exceptions. Space Bunny Free and LongCat 2.5 Preview Free are explicitly zero-retention and exclude training; Jev 1.13 Free has no listed exception to Zen's default. Big Pickle, both MiMo models, and Ling 3.0 Flash Fin Free may use collected data to improve models; Muse Spark 1.3 Contributor Free may use prompts and completions to train future Meta models; both Nemotron free models are trial-use only and must not receive personal or confidential data. For work that may contain private code or secrets, use only models covered by a current zero-retention policy; never send sensitive content to a training-use or trial-only model. Recheck the [Zen privacy terms](https://opencode.ai/docs/zen/) before dispatch. |
| Capability checks | The Zen documentation does not specify per-model context windows, rate limits, or tool-use support. Before assigning a model to coding work, run a smoke test with non-sensitive input to verify the required context size, rate behavior, and tool calls. |
| Candidate preference | Prefer a free model only after its coding behavior has been validated on a representative non-sensitive task; tool-integration evidence does not establish model coding quality. |
| Default | Promotional free access can end or change. A configured Firstmate dispatch profile may pin a free model only when `fm-spawn.sh` rechecks availability and free pricing at spawn time; dispatch refuses when either check fails. Recheck policy and capability before changing the pinned model. |

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

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.
