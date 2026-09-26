Mode: AGY foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_AGY_WATCH_CHECKPOINT:-${FM_CODEX_WATCH_CHECKPOINT:-180}}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to AGY, then start the next checkpoint.
6. Never use shell `&` or unmanaged background commands for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as AGY's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-pretool-check-agy.sh`) registered in `.agents/hooks.json`.
8. Turn-end guard: a Stop hook (`bin/fm-turnend-guard-agy.sh`) registered in `.agents/hooks.json` checks watcher health before any turn ends.
   If supervision is needed but unheld, it forces a continuation turn carrying the repair instruction.
9. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

AGY cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
