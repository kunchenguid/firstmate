Mode: Copilot foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Copilot, then start the next checkpoint.
6. Never use shell `&` or Copilot background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Copilot's normal supervision command.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Copilot cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.

Copilot has no blocking turn-end guard: its hooks cannot force a continued turn the way codex's and claude's Stop hooks can, so the active checkpoint loop above is the only supervision backstop.
Keep the loop running while any work is in flight, and if a turn ever ends with the loop stopped, resume the checkpoint immediately on the next turn.
