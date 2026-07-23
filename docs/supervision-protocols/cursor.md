Mode: Cursor background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run `bin/fm-watch-arm.sh` as its own Cursor Agent background Shell task (`block_until_ms: 0`).
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the beforeShellExecution seatbelt (`bin/fm-arm-pretool-check.sh --cursor`) registered in `.cursor/hooks.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. Ordinary wake: when the background Shell task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, then start exactly one fresh background Shell task before running other fleet commands to handle the wake.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
9. The existing turn-end stop hook (`bin/fm-turnend-guard-cursor.sh`) remains the final backstop and is not replaced by this command gate.
10. Recovery only: if a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Cursor background Shell mechanism.
11. Do not send idle progress while the watcher is parked.

Cursor Agent's background Shell completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
