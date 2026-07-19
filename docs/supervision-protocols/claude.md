Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-arm.sh` as its own Claude Code background task.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. When the background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, then start exactly one fresh background task before running other fleet commands to handle the wake.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
9. The continuity PreToolUse gate allows wake drain and watcher arm recovery, and refuses only other `bin/fm-*.sh` fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
10. The existing turn-end guard remains unchanged as the final backstop and is not replaced by this command gate.
11. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
12. Do not send idle progress while the watcher is parked.

Claude Code's background task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
