Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-arm.sh` as its own Claude Code background task.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task stays live until that existing cycle ends; it does not exit immediately.
7. Treat `watcher: FAILED - no live watcher with a fresh beacon` as an alarm and repair it before ending the turn.
8. When the background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle them, then start exactly one fresh background task.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
9. A completion carrying NO wake reason usually means the harness reaped the background task.
   That is not a lost wake and not a supervision lapse: the watcher runs detached and survives the reap.
   Drain, then re-arm as usual - the re-arm reports `attached` onto that still-live watcher.
10. `watcher: idle-exit ...` means the fleet is empty, X mode is off, and nothing needs supervising.
    It is not a wake reason: do not re-arm on it. The next spawn arms a fresh watcher.
11. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
12. Do not send idle progress while the watcher is parked.

Claude Code's background task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present, so the background task stays live until that cycle ends.
The arm is a follower of a detached watcher, so reaping this background task no longer takes supervision down with it; `bin/fm-watch-arm.sh`'s header owns that mechanism.
