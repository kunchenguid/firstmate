Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
When work still needs supervision, the tracked Codex Stop hook re-blocks after a quiet checkpoint expires until another foreground checkpoint proves a live watcher or the fleet becomes empty.
That continuation is owned by the active Codex Stop surface and never by a reaped child, a worker pane, or a second primary.

Away mode needs a verified primary tmux or Herdr pane where the daemon can deliver its return and escalation messages.
An external Codex thread identified by `CODEX_THREAD_ID` without either pane has no safe asynchronous callback, so both `bin/fm-afk-launch.sh` and its common `bin/fm-afk-start.sh` entry refuse before they write away state.
Do not supply `FM_SUPERVISOR_TARGET` for a worker pane.
Keep foreground checkpoints running while present, or restart the primary in tmux or Herdr before leaving work unattended.
