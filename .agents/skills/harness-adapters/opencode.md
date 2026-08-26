## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.6; 1.18.4 busy-queue re-verified 2026-07-20)

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so use `bin/fm-control.sh <task-id> relaunch` for a wedged pane |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

**Busy-queued Enter (opencode 1.18.4).**
While opencode is mid-turn, the composer accepts Enter as a "send when the turn
ends" keystroke but does not clear the typed text from the composer until the
turn actually finishes.
Without a conversion, every typed-plane `fm-send` to a busy opencode pane exits non-zero on a false "Enter swallowed", and every daemon escalation that lands while the primary is mid-turn is treated as wedged.
Both tmux and herdr delegate this exception to the one policy in `fm_composer_queued_enter_verdict` (`bin/fm-composer-lib.sh`), with backend-specific signals documented in `docs/tmux-backend.md` and `docs/herdr-backend.md`.
Regression coverage is `tests/fm-tmux-submit-busy.test.sh`, `tests/fm-composer-lib.test.sh`, and `tests/fm-backend-herdr.test.sh`; the live Herdr Claude guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

**Primary-session guard fact (verified 2026-07-08, OpenCode 1.17.6).**
The firstmate PRIMARY's own `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `bin/fm-turnend-guard.sh` returns 2.
The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher wake supervision and coordinates with the guard plugin before the guard tries a blind-turn follow-up.
The follow-up was verified in the interactive TUI; `opencode run` can exit before displaying a queued follow-up, so the adapter is fail-open in headless mode.

