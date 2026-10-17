Mode: Claude Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`, unless the wake arrived pre-drained (step 3).
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`), never by you.
   Every turn end while supervision is needed launches or attaches one home-scoped watcher cycle with no model command and no model tokens.
   An actionable close wakes you through the hook's exit-2 rewake, delivered as a `Stop hook feedback` message.
3. On a `Stop hook feedback` wake (`signal:`, `stale:`, `check:`, or `heartbeat`), handle the wake from the `WAKE PRESENTATION` the banner carries: the hook already ran `bin/fm-wake-drain.sh` for you, and running it again is needed only when the banner says the presentation was cut.
   Its acknowledgement, including the mark-processed of any presented branch outcome, runs automatically when the turn ends, so end the turn only once the wake is handled; `bin/fm-wake-ack.sh hold` keeps the wake open past this turn, and an interrupted or errored turn leaves it queued for the next drain ([`watcher-continuity.md`](../watcher-continuity.md#pre-drained-wakes-and-the-turn-end-acknowledgement)).
   A banner without a `WAKE PRESENTATION` asks you to run `bin/fm-wake-drain.sh` first and run its `WAKE_ACK_REQUIRED` command yourself, as step 1 says.
   Empty plumbing closes (`check: rearm-resurface`, `check: inactive-outcome` with nothing to present) are acknowledged by the hook and never reach you.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; act only on real wake records, the presentation's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
4. On the one `Stop hook feedback` automatic-mechanism failure notice (`firstmate watcher auto-arm FAILED ...`), drain, inspect the automatic mechanism failure, and do not turn the notice into a repeating manual-arm loop.
5. If the Stop hook does not claim the home or reports an exhausted failure, inspect its registration and watcher startup path before ending blind.
   Keep the Stop-owned automatic mechanism as the only Claude arm owner.
6. Treat `watcher: started ...` and `watcher: attached ...` inside automatic arm output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a rewake and the next Stop-launched arm, while the bounded turn-end guard prevents a blind Stop when recovery did not start.
   No PreToolUse hook denies fleet commands based on watcher status.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. The turn-end guard (`bin/fm-turnend-guard.sh --claude`) remains the final backstop.
   It requires the PID-strict live-watcher and fresh-beacon predicate at the Stop boundary, except for the Claude-specific foreign-live-owner safe exit owned by [`turnend-guard.md`](../turnend-guard.md#guard-predicates); that document also owns the distinct model-aware mid-turn pull-guard rules.
   Otherwise, it allows the stop when a watcher is healthy or an open auto-arm generation claim owns recovery, while fresh failure epochs advance the bounded one-time attended fail-open progression described there.
9. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the Stop hook foregrounds on a home that opted out of the [supervision host](../supervision-host.md) (`config/supervision-host-off`).
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract and the Claude ownership model.
