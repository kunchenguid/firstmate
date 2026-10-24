Mode: Antigravity CLI (agy) background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with Antigravity's tracked background command tool, as its own standalone call:

   `run_command` with `WaitMsBeforeAsync: 1000` (and `IsDaemon: false`) on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn by calling no more tools.
   The background arm remains the live wait until it returns an actionable wake or failure.
   Do not poll with `manage_task`.
8. Waiting is silent: do not send idle progress while the watcher is parked in the background.
9. Never use shell `&` or `IsDaemon: true` for firstmate supervision.
10. Never bundle the arm onto another command.

Antigravity's reactive wakeup automatically resumes execution when the background `bin/fm-watch-arm.sh` task completes.
When a background-task completion message arrives for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`, then run the exact `WAKE_ACK_REQUIRED --ack-through` command.
3. Ordinary wake: re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call (`run_command` with `WaitMsBeforeAsync: 1000`) if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
4. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The primary project `Stop` hook runs `bin/fm-turnend-guard-agy.sh` as a fast non-blocking backstop, not the normal wake path.
When a healthy watcher cycle is already running, the `Stop` hook returns `{"decision": "allow"}` immediately.
When active tasks are in flight with no healthy watcher cycle (or when unread wakes remain queued in `state/.wake-queue`), the `Stop` hook returns a bounded `{"decision": "continue", "reason": "..."}` follow-up so the session drains or re-arms with the background protocol above before ending the turn.
