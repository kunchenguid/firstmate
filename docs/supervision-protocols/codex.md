Mode: Codex foreground checkpoint.

When this session owns supervision:
1. Drain first with `bin/fm-wake-drain.sh`.
   Apply the section 8 reconciliation rules, then run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; interruption before it leaves the work durable.
2. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
3. On `signal:`, `stale:`, `check:`, or `heartbeat`, drain and handle the wakes before the next checkpoint.
4. On `checkpoint:` or exit 124 without a wake, drain anyway, process any now-visible user message, then start the next checkpoint.
5. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
6. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
7. Missing or failed cycle only: drain, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
