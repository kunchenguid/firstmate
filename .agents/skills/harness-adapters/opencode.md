# harness-adapters: opencode

Load this reference only when an OpenCode runtime is being selected, spawned, recovered, interrupted, exited, resumed, or verified.
The core [harness-adapters](SKILL.md) reference owns universal selection, dispatch, backend, and verification invariants.
Worker operation facts below were verified 2026-06-11 across v1.15.7 through 1.17.6 unless a narrower fact gives its own evidence.
OpenCode 1.18.4 busy-queue behavior was re-verified 2026-07-20.

## Launch profile and model discovery

| Axis | Verified support |
|---|---|
| Model flag | `--model <provider/model>` |
| Effort flag | none for firstmate's interactive launch |
| Evidence | Verified on opencode 1.17.6. |

`opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag.
Run `opencode models [provider]` to list available provider/model identifiers.
If the current authenticated environment does not establish the requested model or provider relationship, fail loudly and report the unresolved candidate.

## Worker operation facts

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt`, with a dotted spinner footer and no `to` |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |
| Skill invocation | Use natural language when exact slash-command behavior is uncertain. |
| Resume | Relaunch with `--continue`, then send the next instruction via `fm-send` once the TUI is up. |

No trust dialog is verified.
OpenCode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

**Busy-queued Enter, opencode 1.18.4, tmux backend fix, herdr known gap.**
While opencode is mid-turn, the composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text from the composer until the turn actually finishes.
Without a fix, every `fm-send` to a busy opencode pane exits non-zero on a false "Enter swallowed", and every daemon escalation that lands while the primary is mid-turn is treated as wedged.
The shared `fm_tmux_submit_enter_core` in `bin/fm-tmux-lib.sh` now falls back to `fm_pane_is_busy` once the Enter-retry budget is spent.
A busy pane means the Enter was accepted and queued, reported as `empty` so the caller does not re-send, while an idle pane keeps `pending` as a genuine swallow.
The herdr adapter observes the same opencode behavior but needs a separate fix.
It is recorded as a known gap in [`docs/herdr-backend.md`](../../../docs/herdr-backend.md) rather than patched here, so the tmux adapter does not paper over a herdr-specific shape.
Regression coverage: `tests/fm-tmux-submit-busy.test.sh` covers the four scenarios, busy plus pending to `empty`, idle plus pending to `pending`, busy plus cleared to `empty`, and idle plus cleared to `empty`.

## Primary integration facts

`opencode` exposes passive lifecycle callbacks for the primary turn-end guard, so its tracked primary adapter forces one bounded follow-up when the shared predicate blocks.
`opencode` blocks watcher-arm anti-patterns by throwing from `tool.execute.before`.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.

`bin/fm-sessionstart-nudge.sh` is verified on 1.17.18.
`session.created` plus `client.session.promptAsync` starts the nudge turn in the TUI, while `opencode run` remains fail-open headless.

**Primary-session guard fact, verified 2026-07-08 on OpenCode 1.17.6.**
The firstmate primary's own `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `bin/fm-turnend-guard.sh` returns 2.
The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher wake supervision and coordinates with the guard plugin before the guard tries a blind-turn follow-up.
The follow-up was verified in the interactive TUI.
`opencode run` can exit before displaying a queued follow-up, so the adapter is fail-open in headless mode.
