Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. After the first cycle, the tracked Codex `Stop` hook owns checkpoint continuity through `bin/fm-turnend-guard.sh --codex`.
   Every Stop while supervision is still needed runs one bounded foreground checkpoint synchronously inside the hook.
   An actionable close blocks the Stop with the real watcher reason so Codex continues and drains the durable wake.
5. Ordinary wake: if the command or Stop feedback prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes and handle that wake, then end the continuation.
   The next Stop hook starts the next checkpoint automatically; do not start it from model memory.
6. If the command or Stop feedback prints `checkpoint:` or reports a quiet checkpoint, drain queued wakes anyway, process any queued user message now visible to Codex, then end the continuation.
   The next Stop hook starts the next checkpoint automatically while supervision is still needed.
7. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
8. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
9. Failure or missing cycle only: drain queued wakes and inspect the failure.
   End the continuation after handling; the Stop hook retries the owned foreground checkpoint while supervision is still needed.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
The Stop hook has a 600-second execution bound, comfortably above the default 180-second checkpoint, and never detaches the watcher from its owned process tree.
