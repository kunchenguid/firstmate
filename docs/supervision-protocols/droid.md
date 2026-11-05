Mode: Droid tracked background cycle.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm exactly one fire-and-forget Droid native tracked background job running `bin/fm-watch-droid-background.sh`.
   Use Execute's native `fireAndForget: true`, never shell `&`, nohup, or disown.
4. On the job's completion notification, drain queued wakes first, handle the actionable wake (`signal:`, `stale:`, `check:`, or `heartbeat`) under the ordinary wake contract, then arm the next background cycle.
   If away or quiet mode became active while the job was running, follow the [shared return classifier](../../.agents/skills/afk/SKILL.md#how-to-exit-the-return) instead, preserving that mode and its daemon's supervision ownership.
5. Quiet checkpoints stay inside that job and produce no notification or agent turn.
   End turns freely while the cycle is running so captain messages can be handled between wakes; keep exactly one cycle and do not poll or wait on its job id.
6. Fallback: when background completion notifications are unavailable or unreliable, run the bounded foreground loop with `bin/fm-watch-checkpoint.sh --seconds "${FM_DROID_WATCH_CHECKPOINT:-180}"`; drain and handle wakes or queued captain messages after each return, then take the next checkpoint.
7. Do not run `bin/fm-watch-arm.sh` as Droid's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.factory/settings.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh background cycle; use the foreground fallback if completion notifications cannot be relied on after a session restart.

The wrapper's header and `--help` own checkpoint timing and the consecutive-failure bound.
