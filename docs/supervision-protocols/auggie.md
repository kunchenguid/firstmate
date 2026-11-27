Mode: Auggie foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"` as its own bash tool call.
   Pass that call an explicit tool timeout above the checkpoint bound, for example 240 seconds for the 180-second default, so the tool never kills the watcher mid-cycle; auggie's timeout kills the whole process tree.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to you, then start the next checkpoint.
6. Start the next checkpoint before ending any turn while supervision is needed.
   No hook enforces this on auggie: its Stop hook runs in the background, cannot block, and its output never reaches you, so this instruction is the only guard against a turn ending blind.
7. Never use shell `&` for firstmate watcher supervision, and do not run `bin/fm-watch-arm.sh` as normal supervision.
   A backgrounded, piped, or bundled watcher command is denied by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.augment/settings.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Auggie cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled.
[`turnend-guard.md`](../turnend-guard.md) owns the auggie compatibility limits.
