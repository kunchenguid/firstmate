Mode: Grok long-lived background-notify supervision.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
   Until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with Grok's tracked background tool, as its own call:

   `run_terminal_command` with `background: true` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-grok-longrun.sh`

4. The long-runner owns `bin/fm-watch-arm.sh` in the foreground.
   It keeps the same Grok tracked task open across routine declared-pause and captain-hold rechecks.
   Those internal cycle closes never become Grok `task_completed` prompts.
5. The long-runner returns only for a real actionable watcher result or failure.
   Grok's native tracked-task completion then wakes the model immediately.
6. Waiting is silent.
7. Never use shell `&` for firstmate supervision.
8. Never bundle the long-runner onto another command.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's Grok hooks are trusted.

When Grok injects a background-task-completed reminder for the long-runner:

1. Run `bin/fm-wake-drain.sh` first.
2. Optionally fetch the task output with `get_command_or_subagent_output(<task_id>)` for the reason line.
3. Handle `signal`, non-routine `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Re-arm one new tracked `bin/fm-watch-grok-longrun.sh` task if work remains in flight or Relay still needs polling.
5. Do not invent a wake from a `watcher: started ...` or `watcher: attached ...` line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
6. See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer singleton, liveness, recovery, and clean-close failure contract.

The primary project Stop hook runs `bin/fm-turnend-guard-grok.sh` as a strict backstop, not the normal wake path.
[`turnend-guard.md`](../turnend-guard.md) owns its running-payload capability selection between native same-process blocking and the pre-native bounded resume fallback.
After any forced continuation, arm the long-lived tracked watcher through the first-cycle procedure above.

Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` may wait for background process exit but does not reliably surface full auto-wake model output; do not run the primary firstmate as a one-shot headless process.
