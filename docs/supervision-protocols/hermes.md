Mode: Hermes background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run `bin/fm-watch-arm.sh` as its own Hermes `terminal` background task with completion notify enabled (`background=true` and `notify_on_complete=true` on the Hermes terminal tool).
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse-equivalent seatbelt (`bin/fm-arm-pretool-check.sh`) when Hermes shell hooks are installed via `bin/fm-hermes-install-primary-hooks.sh`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. Ordinary wake: when the Hermes background-task completion notification arrives with `signal:`, `stale:`, `check:`, or `heartbeat` in the arm output, drain queued wakes, then start exactly one fresh background arm before running other fleet commands to handle the wake.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
9. The continuity PreToolUse gate allows wake drain, watcher arm recovery, and fail-closed teardown, and refuses only other `bin/fm-*.sh` fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
10. Hermes has no general Claude-style Stop block for every turn end.
    Rely on background-notify as the live wake path.
    Install the optional passive turn-end observer from `bin/fm-hermes-install-primary-hooks.sh` so a blind end (tasks in flight, no live watcher) writes a durable, rate-limited marker at `state/.hermes-turnend-alarm`; the next fleet command still trips `bin/fm-guard.sh`'s independent watcher-down banner. The observer does not force a same-session follow-up the way Claude or Codex Stop hooks do.
11. Recovery only: if a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Hermes background-notify mechanism.
12. Do not send idle progress while the watcher is parked.

Hermes Agent's terminal `notify_on_complete` is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
See [`hermes-primary.md`](../hermes-primary.md) for hook install, env markers, residual gaps, and empirical evidence.
