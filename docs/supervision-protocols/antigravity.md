Mode: Antigravity agentic supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Ordinary wake: drain queued wakes, handle that wake, reconcile open decisions and unread status lines, and run the printed `--ack-through` command.
4. Supervision: Antigravity manages background tasks through its native agentic runtime (`manage_task`, `run_command`, `schedule`, `invoke_subagent`).
   Reactive wakeup is handled automatically by the Antigravity messaging system when background tasks complete.
   For fleet-wide watcher polling, run `bin/fm-watch.sh` or `bin/fm-watch-checkpoint.sh`.
