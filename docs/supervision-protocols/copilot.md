Mode: GitHub Copilot CLI agentStop-hook-owned park.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the `agentStop` hook, never by you.
   The synchronous hook parks the turn boundary on one home-scoped watcher cycle and returns an actionable close as a forced continuation.
3. On a watcher continuation, run `bin/fm-wake-drain.sh` first and handle the event.
   Do not run `bin/fm-watch-arm.sh` after an ordinary event; the next turn end parks again automatically while supervision is still needed.
4. On a turn-end-guard continuation, the park could not establish a live cycle.
   Inspect the hook registration and watcher startup path rather than creating a repeating manual-arm loop.
5. Copilot CLI overrides an eighth consecutive blocked stop.
   Firstmate stops at seven, using the last continuation to report the ceiling; queued events remain durable, and a real captain prompt resets the sequence.
6. Waiting on the hook-owned park is silent: do not send idle progress while it is parked.

The watcher remains `bin/fm-watch.sh`, and the park runs `bin/fm-watch-arm.sh` as its tracked child.
The private supersession records are `state/.copilot-park-owner` and `state/.copilot-park-owner.lock`.
