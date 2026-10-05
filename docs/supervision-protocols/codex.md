Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle and reconcile them, run the drain's exact generation-bound `WAKE_ACK_REQUIRED` command, then start the next checkpoint in the same turn.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, handle and acknowledge them, process any queued user message now visible to Codex, then start the next checkpoint in the same turn.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
Each checkpoint releases its watcher lock when it returns; a returned checkpoint is no longer supervision, even if its tool output previously reported a running session.
While supervision is needed, continue calling and awaiting checkpoints rather than sending a final response after a wake, quiet expiry, or Stop recovery.
The Stop guard permits only one forced continuation and cannot maintain an unattended foreground loop after the model ends its turn.
If the hosting surface cannot keep that loop active, report the limitation and obtain a runtime choice with supported persistent supervision.
