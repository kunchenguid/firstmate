Mode: Grok background-notify supervision.

When this session owns supervision, unless a live away-mode daemon owns it instead:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with Grok's tracked background tool, as its own call:

   `run_terminal_command` with `background: true` on:
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
    A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's Grok hooks are trusted.

Grok injects a synthetic user message with `synthetic_reason: task_completed` when the background arm completes.
When you see a background-task-completed system reminder for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally fetch arm output with `get_command_or_subagent_output(<task_id>)` for the reason line.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call if work remains in flight or Relay still needs polling.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The primary project Stop hook runs `bin/fm-turnend-guard-grok.sh` as a backstop, not the normal wake path.
[`turnend-guard.md`](../turnend-guard.md) owns its running-payload capability selection between native same-process blocking and the pre-native bounded resume fallback.
After any forced continuation, arm the watcher with the background protocol above.

Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` may wait for background process exit but does not reliably surface full auto-wake model output; do not run the primary firstmate as a one-shot headless process.
