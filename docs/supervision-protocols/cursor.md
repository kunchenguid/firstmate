Mode: Cursor tracked background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-arm.sh` as its own Shell tool call with `block_until_ms: 0`.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   When Cursor's account rollout executes project hooks, a shell `&`, a truncating pipe, or bundling is also denied automatically by the `preToolUse` seatbelt registered in `.cursor/hooks.json`; otherwise this instruction is the guard (docs/turnend-guard.md).
6. Perform the one non-blocking status check required for a directly backgrounded Shell call.
7. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task stays live until that existing cycle ends.
8. Treat `watcher: FAILED - no live watcher with a fresh beacon` as an alarm and repair it before ending the turn.
9. When Cursor reports that the background task completed with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle them, then start exactly one fresh background task.
10. Do not invent a wake from an attach-status line alone.
    Drain and act only on real wake records or a real watcher reason line.
11. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same tracked background task mechanism.
12. Do not send idle progress while the watcher is parked.

Cursor's tracked Shell task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified arm wrapper.
The tracked stop hook adapts Cursor's `loop_count` and `followup_message` fields to the shared turn-end guard as a one-follow-up backstop.
