Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-arm.sh` as its own Claude Code background task.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists **only while that background task is still running**.
   On attach, the background task stays live until that existing cycle ends; it does not exit immediately.
   Those lines stay in the buffer after the task completes, where they are a record of the past, not a claim about now: a completed task never means supervision is live, whatever its earlier lines say.
7. Treat any `watcher: FAILED ...` line as an alarm and repair it before ending the turn.
   `watcher: FAILED - no live watcher with a fresh beacon` means the arm could not confirm one at all.
   `watcher: FAILED - attached cycle ended ...` means an attach ended and nothing is watching now; drain queued wakes, then re-arm.
8. When the background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle them, then start exactly one fresh background task.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
   A completed task whose last line is neither a wake reason nor a `FAILED` line is itself an alarm: re-arm rather than assume the cycle is still live.
9. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
10. Do not send idle progress while the watcher is parked.

Claude Code's background task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present, so the background task stays live until that cycle ends.

When `state/.afk` exists, the away daemon replaces `bin/fm-watch-arm.sh` as the tracked background task and owns the watcher as its child.
Routine wakes stay inside the daemon's bash triage and leave that task parked.
A captain-relevant batch completes the task with an `afk-reap-wake:` reason, which uses this same native completion notification without typing into the Claude composer.
Drain `state/.wake-queue`, handle the batch, and restart the away daemon as a fresh native tracked background task if away mode remains active.
