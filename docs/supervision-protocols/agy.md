<!-- fm:supervision-protocol:v3 harness=agy -->
Mode: Antigravity background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with Antigravity's tracked background tool, as its own call:

   `run_command` with `WaitMsBeforeAsync: 500`, `IsDaemon: false`, and no `NotificationTimeoutSeconds` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec __FM_AGY_ARM__`

4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After the arm command moves to the background, end the turn.
   The background arm remains the live wait until it exits with an actionable wake or failure, keeping the TUI idle and captain messages unqueued while waiting.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh --agy`).

Antigravity's reactive wakeup automatically resumes the session when the background task exits with a wake or failure.
When you wake from the background arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`, then run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
3. Ordinary wake: re-arm the next cycle with the same background `__FM_AGY_ARM__` call if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
4. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The primary project `Stop` hook in `.agents/hooks.json` runs `bin/fm-turnend-guard-agy.sh` as a fast non-blocking turn-end backstop, never a synchronous park.
[`turnend-guard.md`](../turnend-guard.md) owns its guard rails and bounded repair nag.
