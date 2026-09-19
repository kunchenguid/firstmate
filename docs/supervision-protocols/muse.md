Mode: Muse foreground checkpoint.

Added 2026-09-15 on the captain's explicit order to run the ProspectPilot secondmates on Muse Spark.
Muse is not a verified primary harness: it has no firstmate Stop-hook rewake, so supervision here must never depend on a background task or a hook waking the model.
It reuses the harness-agnostic foreground checkpoint that Codex uses.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_MUSE_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, check the steering inbox for new instruction records, then start the next checkpoint.
6. Never use shell `&` or Muse background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as the normal supervision command; it relies on a Stop-hook rewake Muse does not provide.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.
9. Never end a turn while supervision is required without a checkpoint running: with no Stop-hook rewake, an ended turn is a session nobody wakes.

Muse cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so steering messages and queued wakes are handled without relying on background-task or hook wake semantics.
