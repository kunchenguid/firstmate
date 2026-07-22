Mode: traex foreground checkpoint.

traex (TRAE CLI 2.0) is a codex fork and shares codex's supervision shape: it cannot reason while a foreground tool call is running, so the watcher runs as a bounded foreground checkpoint, not a background arm.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. If the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to traex, then start the next checkpoint.
6. Never use shell `&` or traex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch.sh` directly and do not run `bin/fm-watch-arm.sh` as traex's normal supervision command.
   If either is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.trae/hooks.json`.

traex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
A 200-second foreground shell call was verified to return its output to the model (scout `traex-parity-study-n7` §4.4), so the checkpoint length is not truncated by the harness.
traex's provider may queue for capacity (`Queued for capacity ... esc to interrupt`), which lengthens turns without breaking supervision; do not size the checkpoint by the fastest turn.
The `.trae/hooks.json` PreToolUse and Stop hooks load only after the firstmate checkout is granted directory trust and a one-time hooks-review "Trust all"; until that is done the primary guard and seatbelts are inert, so `bin/fm-guard.sh` remains the pull-based backstop.
