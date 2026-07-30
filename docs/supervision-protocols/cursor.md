Mode: Cursor foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CURSOR_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Cursor, then start the next checkpoint.
6. Never use shell `&` or a Cursor background task for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Cursor's normal supervision command; the bounded foreground checkpoint is the protocol.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Cursor cannot reason while a foreground tool call is running, like Codex.
The bounded checkpoint returns control regularly so user messages and queued wakes are handled without relying on background-task wake semantics.

Cursor has no firstmate-wired primary Stop-hook turn-end guard or PreToolUse arm seatbelt.
Cursor discovers hooks only at the project git root's `.cursor/hooks.json` and exposes no per-invocation override, so a tracked primary hook would also fire in every same-repo worker worktree and block those workers from installing their own turn-end hook.
Firstmate therefore keeps the primary integration conservative: the universal next-command alarm (`bin/fm-guard.sh`) is the turn-end backstop, and this bounded checkpoint keeps the session returning to supervise.
`docs/turnend-guard.md` "Cursor" owns this fail-open boundary.
