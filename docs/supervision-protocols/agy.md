Mode: Antigravity background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: arm with `run_command` as its own standalone background call:

   `run_command` with:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The background arm remains the live wait until it returns an actionable wake or failure.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.

When the background task completes and notifies with output:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
3. Ordinary wake: re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call if work remains in flight or X mode still needs polling.
4. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
