Mode: Devin foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-checkpoint.sh --seconds __FM_CODEX_WATCH_CHECKPOINT__` as one foreground tool call.
4. Never bundle the checkpoint with unrelated commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt registered in `.devin/config.json`.
6. When the checkpoint returns with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle them, then run one fresh checkpoint.
7. A timeout is only a bounded control return.
   If work remains in flight, run another checkpoint after handling user input and queued wakes.
8. Treat any failed checkpoint as an alarm and repair it before ending the turn.
9. Do not send idle progress while a checkpoint is running.

Devin has no verified background-task completion wake contract in Firstmate.
The bounded foreground checkpoint is the conservative supported mechanism, matching Codex's supervision shape while retaining Devin's native blocking Stop-hook backstop.
