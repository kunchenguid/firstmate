Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
   The required immediate drain consumes this owned checkpoint exit's single-use rollover marker without reporting the expected watcher gap as watcher-down.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
   Exit 124 is the intended quiet rollover, and the required immediate drain consumes the same single-use marker without reporting that expected gap as watcher-down.
   The marker is not a health claim, so the turn-end guard still refuses a blind turn and any later drain or fleet operation still reports a missing watcher until the next checkpoint starts.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
If the foreground checkpoint process is interrupted or disconnected, its timeout owner terminates and reaps the exact watcher process group so no orphan can retain the home lock.
