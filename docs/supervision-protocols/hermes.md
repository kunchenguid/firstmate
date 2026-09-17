Mode: Hermes pre_verify bounded continuation + background watcher.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with Hermes background terminal:

   terminal(command="[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh", background=True, notify=['wake:'])

4. Trust only the arm's one-line status.
   `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
5. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
6. After a successful start or attach status, end the turn.
   The background arm remains the live wait until it returns an actionable wake or failure.
7. Waiting is silent.
8. Never use shell `&` for firstmate supervision.
9. Never bundle the arm onto another command.

The `pre_verify` hook provides bounded continuation: while the wake queue is non-empty or workers are active, the plugin forces one continuation turn to drain the queue. This is bounded by agent.max_verify_nudges (default ~3), so it cannot loop infinitely.

On a background-task-completed notification for the watcher arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
3. Ordinary wake: re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call if the home still needs supervision.
4. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

Known gaps (v1):
- No hard turn-end block (only bounded continuation). A captain message always terminates the guard.
- No instruction refresh on `/compact` (CLI-side session-start hook does not fire on compact). Documented limitation.
- Background watcher does not survive gateway restart; next session start re-arms.
- No semantic busy-state events; worker state is inferred from process presence + `state/<id>.progress` file.
