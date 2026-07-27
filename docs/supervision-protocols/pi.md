Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi`, after approving project trust once per clone); if not, restart with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. First cycle only: make the one required `fm_watch_arm_pi` call.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pi` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns every later successor launch.
6. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
7. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_pi` again because continuity is extension-owned rather than model-memory-owned.
8. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
9. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_pi`, and restart Pi with both extensions loaded if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
10. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.
