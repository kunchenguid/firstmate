Mode: Cursor stop-hook-owned park.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the `stop` hook (`bin/fm-turnend-guard-cursor.sh`), never by you.
   Cursor runs that hook synchronously and awaits it, so every turn end while supervision is needed parks the turn boundary open on one home-scoped watcher cycle, with no model command and no model tokens spent while parked.
3. An actionable close wakes you as a follow-up turn carrying the `watcher` operational kind.
   On that wake, run `bin/fm-wake-drain.sh` first and handle it.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end parks again automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
4. The captain keeps control while the hook is parked.
   A message typed into a parked Cursor pane is accepted and runs its turn immediately, but the older park remains the recorded owner until that turn ends and the next `stop` hook claims the baton.
   An actionable watcher close in that window can still be delivered by the older park as one follow-up.
   This is bounded and safe: only one park exists in that window, so the event is a real wake rather than a stale duplicate of another park's wake, the durable wake queue makes handling idempotent, and the next `stop` claim makes an older park that is still running stand down without emitting.
   The private supersession records are `state/.cursor-park-owner` and its short publication and commit lock `state/.cursor-park-owner.lock`.
5. On a `turn-end-guard` follow-up, the park could not establish a live cycle.
   Inspect the watcher startup path rather than turning the notice into a repeating manual-arm loop; the nag is bounded by `FM_CURSOR_TURNEND_BLOCK_BUDGET` (default 3) and then stops on its own.
6. Treat `watcher: started ...` and `watcher: attached ...` inside park output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a follow-up and the next park.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. Waiting on the hook-owned park is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the `stop` hook runs as its own tracked child.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

Exit status 2 is a silent no-op on Cursor's `stop` step, so this adapter never blocks a turn end and instead forces one bounded follow-up, which [`turnend-guard.md`](../turnend-guard.md) accepts as an equal alternative.
That document owns the double loop bound, the supersession contract, and the compatibility limits, including that a Cursor primary must be launched with `--trust` for its project hooks to load at all.
Cursor's `beforeSubmitPrompt` step fires once for a real captain message and not for hook-driven follow-ups, so it could invalidate the baton at the start of this window, but that registration is deliberately deferred alongside the `preCompact` surface.
