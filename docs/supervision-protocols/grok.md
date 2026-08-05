Mode: Grok background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Arm with Grok's tracked background tool, as its own call:

   `run_terminal_command` with `background: true` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Trust only the arm's status lines.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists **while that background task is still running**.
   On attach, the background task stays live until that existing cycle ends; it does not exit immediately.
   Once the task has completed, those lines are history, not a claim about now.
6. `watcher: FAILED ...` means supervision is down; fix and re-arm.
   That includes `watcher: FAILED - attached cycle ended ...` (the attach ended and nothing is watching) and `watcher: FAILED - attach interrupted ...` (this arm stopped waiting, so no wake reaches the harness even if the watcher itself is still up).
7. After a successful start or attach status, end the turn.
   The background arm remains the live wait until the cycle ends.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's Grok hooks are trusted.

Grok injects a synthetic user message with `synthetic_reason: task_completed` when the background arm completes.
When you see a background-task-completed system reminder for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally fetch arm output with `get_command_or_subagent_output(<task_id>)` for the reason line.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call if work remains in flight or X mode still needs polling.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records or a real watcher reason line.
   Re-arm attaches to an existing cycle when one is already healthy, so the background task stays live until that cycle ends.
   A completed arm whose last line is neither a wake reason nor a `FAILED` line is itself an alarm: re-arm rather than assume the cycle is still live.

Grok Stop hooks are passive.
The primary project hook runs `bin/fm-turnend-guard-grok.sh`, which forces at most one same-session follow-up via `grok --resume` when a turn would end blind.
That is a backstop, not the normal wake path.
After any forced follow-up, arm the watcher with the background protocol above.

Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` may wait for background process exit but does not reliably surface full auto-wake model output; do not run the primary firstmate as a one-shot headless process.
