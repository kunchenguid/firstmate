Mode: Cursor stop-hook-owned supervision.

Verified against cursor-agent 2026.07.23-e383d2b only.
Cursor ships date-stamped builds; re-verify this protocol after any cursor-agent upgrade before trusting it.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Routine watcher arm and re-arm are owned by the `stop` hook (`bin/fm-turnend-guard-cursor.sh`), never by you.
   Every turn end while supervision is needed foregrounds one home-scoped watcher cycle from inside the synchronous stop hook, with no model command and no model tokens spent while parked.
   Cursor's stop hook blocks for its whole `timeout` (600 s in the tracked registration) and then wakes the agent with a `followup_message` when an actionable event arrived.
   An actionable close wakes you through that follow-up message.
3. On a follow-up wake (`signal:`, `stale:`, `check:`, or `heartbeat`), run `bin/fm-wake-drain.sh` first and handle the wake.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real watcher reason line.
4. If the stop hook does not fire or reports an exhausted failure, inspect the `.cursor/hooks.json` registration and the watcher startup path before ending blind.
   The top-level `"version": 1` key is load-bearing: without it cursor silently discards the file and every hook is inert, which is a fail-open supervision hole.
   Keep the stop-hook-owned mechanism as the only Cursor arm owner.
5. Treat `watcher: started ...` and `watcher: attached ...` inside the hook's arm output as proof that one live cycle exists.
   The arm follows verified identity-matched successors instead of exiting when the first cycle ends.
6. The durable wake queue preserves actionable events between a wake and the next stop-launched arm, while the bounded turn-end guard prevents a blind stop when recovery did not start.
   The `preToolUse` hook (matcher `Shell`) denies watcher-arm anti-patterns through `bin/fm-arm-pretool-check.sh --cursor`.
7. The turn-end guard (`bin/fm-turnend-guard.sh`, via the cursor shim) remains the final backstop.
   The shim evaluates the shared predicate on every stop, including a forced follow-up turn (`loop_count > 0`): the arm is stop-hook-owned, so a wake follow-up that itself ends blind re-arms instead of leaving the primary unsupervised until some later turn ends with `loop_count 0`.
   On any blind turn the shim foregrounds the arm and classifies its typed actionable reason lines.
   If the arm closes with `signal:`, `stale:`, `check:`, or `heartbeat` while supervision is still needed, the shim emits a normal wake follow-up that tells you to drain and handle the wake.
   If the arm fails or closes without a typed actionable reason, the shim emits the loud guard banner so hook registration and startup remain diagnosable.
   If the need vanishes or a healthy watcher remains, the shim emits `{}`.
   The `loop_limit: null` registration leaves the continuation budget to the shim, which keeps one session-scoped chain record in `state/.cursor-turnend-chain` (keys `session`, `fail`, `wake`, `reason`, reset on session mismatch): consecutive loud arm-failure follow-ups (`FM_CURSOR_TURNEND_BLOCK_BUDGET`, default 3) and consecutive repeats of the SAME unchanged wake reason (`FM_CURSOR_WAKE_CHAIN_BUDGET`, default 5, with one final diagnostic follow-up at the ceiling).
   A different wake reason is progress and restarts the wake count, so ordinary back-to-back supervision events never exhaust the chain; each kind resets the other, an allowed stop clears the record, and an exhausted failure budget resets rather than silencing the banner permanently.
   If the record cannot be persisted (read-only or full `state/`), the payload's `loop_count` carries the bound instead, so the chain still ends.
8. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.
9. Captain input while the stop hook is parked is buffered, not delivered (verified 2026-08-05): text typed with Enter during a parked stop hook sits unsubmitted in the composer until the forced follow-up turn completes, then needs a second Enter to submit.
   Nothing is lost or cleared - the draft survives the parked window and the follow-up turn.
   If the captain reports a message not going through, a second Enter submits the buffered draft.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the stop hook foregrounds.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

Headless is not a supervision host: `cursor-agent -p` fires only `sessionStart`, never `stop`, so firstmate's primary session must run in the interactive TUI.
