Mode: OMP extension background wake.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm OMP auto-loaded both project extensions (plain `omp`; `.omp/extensions/` auto-loads without a trust gate); if not, restart with `-e __FM_OMP_TURNEND_EXT__ -e __FM_OMP_EXT__`.
3. Arm supervision with the `fm_watch_arm_omp` tool.
   Use `/fm-watch-arm-omp` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through OMP's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_omp` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live OMP process, and follows the successor-before-wake and bounded-failure contract in [`watcher-continuity.md`](../watcher-continuity.md).
   A rejected delivery is recorded in `state/.omp-watch-delivery-failed` for the next session-start digest.
6. After handling that notification, leave any successfully started successor cycle running.
7. If the extension says it already owns an arm child, do not start another cycle.
8. If the extension reports a watcher failure, drain queued notifications, inspect the failure text, and restart OMP with both extensions loaded if needed.
9. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_OMP_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_OMP_TURNEND_EXT__`.
The watcher extension lives at `__FM_OMP_EXT__`.
Both are tracked, project-local `.omp/extensions/*.ts` files that OMP auto-discovers without a trust gate; `bin/fm-session-start.sh` reports when the running OMP session has not loaded both required extensions.
