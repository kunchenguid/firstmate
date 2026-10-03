Mode: Devin Stop-hook-owned park.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the `Stop` hook (`bin/fm-turnend-guard-devin.sh`), never by you.
   Devin runs that hook synchronously and awaits it, so every turn end while supervision is needed parks the turn boundary open on one home-scoped watcher cycle, with no model command and no model tokens spent while parked.
3. An actionable close wakes you as a block-driven continuation inside the same turn, carrying the `watcher` operational kind in the Stop hook's reason text.
   On that wake, run `bin/fm-wake-drain.sh` first and handle it.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end parks again automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real watcher reason line.
4. The captain keeps control while the hook is parked.
   A message typed plus Enter into a parked Devin pane is queued visibly, not delivered: the park reads its own pane, stands down when the queue marker appears, and the queued message drains and runs as its own turn once the turn boundary closes.
   Pressing Escape while parked renders `(esc again to interrupt)` on the spinner row (verified during a real park on devin 3000.11.3) and likewise ends the park so the pending cancel can take effect.
   The next `Stop` parks again after that turn ends.
   The private supersession records are `state/.devin-park-owner` and its publication lock `state/.devin-park-owner.lock`.
5. On a `turn-end-guard` continuation, the park could not establish a live cycle.
   Inspect the watcher startup path rather than turning the notice into a repeating manual-arm loop; the nag is bounded by `FM_DEVIN_TURNEND_BLOCK_BUDGET` (default 3) and then stops on its own.
6. Treat `watcher: started ...` and `watcher: attached ...` inside park output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a block continuation and the next park.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. Waiting on the hook-owned park is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the `Stop` hook runs as its own tracked child.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The wake channel is Devin's `{"decision":"block","reason":...}` stdout object, which Devin maps to one forced continuation inside the same turn; exit 2 is an equivalent channel this adapter does not use.
[`turnend-guard.md`](../turnend-guard.md) owns the prompt_id-keyed loop bound, the supersession contract, and the compatibility limits, including that the park reads its own pane and stands down for queued captain input rather than holding the boundary blind.
