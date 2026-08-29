Mode: Codex bridge-owned persistent watcher.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle only: arm the persistent Codex watcher bridge with one foreground call to `__FM_CODEX_BRIDGE__ arm`.
   The bridge resolves and verifies the exact primary pane, launches the persistent owner in its own tracked non-visible terminal, and keeps one live watcher cycle running across ordinary Codex turn completion; `bin/fm-watch-codex-bridge.sh status` reports its current state.
   The bridge arm is a blessed watcher entry point: never background, pipe, redirect, or bundle it, because the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, registered in `.codex/hooks.json`) denies those shapes automatically.
4. On an injected `FIRSTMATE_OP: v1 watcher:` wake (it arrives in this conversation as a user message), run `bin/fm-wake-drain.sh` first and handle the queued wake.
   The injection is a doorbell, not the source of truth: the durable `.wake-queue` rows and the generation-bound `WAKE_ACK_REQUIRED` acknowledgement stay authoritative, and the bridge never acknowledges a row itself.
5. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not arm another cycle, because watcher continuity is bridge-owned rather than model-memory-owned.
6. Missing, failed, or unhealthy cycle only: if a notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, and arm the bridge again with one foreground call to `__FM_CODEX_BRIDGE__ arm`.
   The arm is idempotent: an already-running bridge for this session is attached; one bound to a replaced session is stopped and replaced.
7. `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"` remains the bounded foreground fallback ONLY while the bridge cannot launch (an unsupported backend or a failed launch): run checkpoints as today until the bridge arms, then stop.
   Never use shell `&` or Codex background tasks for firstmate watcher supervision, and never run `bin/fm-watch.sh` directly; the PreToolUse seatbelt denies both automatically.
8. Away mode: while `state/.afk` exists the away daemon owns supervision and the bridge stands down; after away mode ends, the next turn-end guard repair re-arms the bridge.

The bridge binds one exact owner per home, session lock, watcher generation, backend session, workspace/tab/pane, and Codex primary identity, and stands down instead of injecting when any of them no longer matches; docs/watcher-continuity.md owns the continuity contract.
