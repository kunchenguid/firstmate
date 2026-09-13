Mode: Codex Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the async Stop hook (`bin/fm-codex-stop-autoarm.sh`) registered in `.codex/hooks.json`, never by you.
   Every turn end while supervision is needed launches or attaches one home-scoped watcher cycle with no model command and no model tokens.
   Source `__FM_X_MODE_ENV__` first when Relay is active.
3. An actionable close is delivered back into this Codex thread as an ordinary queued user message that opens with `firstmate watcher wake`.
   On that message, run `bin/fm-wake-drain.sh` first and handle the wake.
   Do not run `bin/fm-watch-arm.sh` or `bin/fm-watch-checkpoint.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
4. On the one `firstmate watcher auto-arm FAILED ...` message, drain, inspect the automatic mechanism failure, and do not turn the notice into a repeating manual-arm loop.
5. `bin/fm-watch-checkpoint.sh` is no longer Codex's supervision command.
   It survives only as an attended diagnostic, and running it as a supervision cycle competes with the hook-owned watcher instead of adding safety.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
   Do not run `bin/fm-watch-arm.sh` directly; a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
7. If the Stop hook does not claim the home or reports an exhausted failure, inspect its registration and watcher startup path before ending blind.
   Keep the Stop-owned automatic mechanism as the only Codex arm owner.
8. The durable wake queue preserves actionable events between a wake and the next Stop-launched arm, while the bounded turn-end guard (`bin/fm-turnend-guard.sh`) prevents a blind Stop when recovery did not start.
9. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the Stop hook foregrounds.
Re-arm attaches to an existing healthy cycle when one is already present.

Delivery of the wake is best effort and the queue is what makes it reliable: `codex queue` accepts a message for a thread whose session is already gone, so a push that lands nowhere is simply re-presented at the next drain.
Never describe it as no-loss or exactly-once.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract, and `bin/fm-codex-stop-autoarm.sh`'s header for why Codex uses a queued message where Claude uses an exit-2 rewake.
