Mode: Cursor Agent background-notify supervision.

Verified for Cursor IDE chat primaries detected as `cursor-agent` via `Cursor Helper` / `Cursor.app` ancestry, and for `cursor-agent` CLI primaries when run interactively.
Empirical wake evidence (2026-07-31, Cursor IDE chat): `bin/fm-watch-arm.sh` as its own Shell tool call backgrounds or blocks until an actionable wake; Cursor delivers a shell-task completion / system notification that wakes the model.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: arm with Cursor's Shell tool as its **own sole command** (never bundled, never piped, never shell `&`):

   `bin/fm-watch-arm.sh`

   When X mode is active, the shell command is:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The armed watcher remains the live wait until it returns an actionable wake or failure and Cursor notifies this session.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command, never truncate its output through a pipe, and never prefix it with env assignments outside the X-mode source form above.
    The shared check script is `bin/fm-arm-pretool-check.sh`; no Cursor-native PreToolUse hook is verified yet, so this primary relies on protocol discipline rather than an automatic deny.

When you see a shell-task completion or system notification for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally read the arm's terminal output for the reason line.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same sole `bin/fm-watch-arm.sh` Shell call if work remains in flight or X mode still needs polling.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

No Cursor-native turn-end Stop hook is verified yet.
The live background arm is the normal wake path; do not end a turn blind while work is under way without that arm running.
Do not run the primary firstmate as a one-shot headless `cursor-agent -p` process for supervision hosting.
