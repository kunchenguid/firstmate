Mode: Cursor background-notify supervision.
Keep exactly one live watcher cycle while any task is in flight.
Arm with `bin/fm-watch-arm.sh` as its own Cursor Shell background task (`block_until_ms: 0`), never shell `&` and never bundled with unrelated commands.
Do not use Codex-style foreground checkpoints (`bin/fm-watch-checkpoint.sh`) on Cursor.
When X mode is active, source `__FM_X_MODE_ENV__` in that same Shell background task before arming so the watcher inherits the 30s cadence.
On every wake (`signal`/`stale`/`check`/`heartbeat`): drain with `bin/fm-wake-drain.sh`, handle the drained records, then re-arm with another standalone Cursor Shell background task.
`watcher: started` and `watcher: healthy` both mean a live cycle already exists - do not start another.
`watcher: FAILED` means no live cycle - drain any queued wakes, then arm one now.
Never end a turn while tasks are in flight without a live cycle.
Tracked Cursor Hooks (`.cursor/hooks.json`) backstop shell `cd` into worktrees, blind shell `&` arms, and turn-end without a live watcher; they do not replace this protocol.
