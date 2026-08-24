Mode: omp native session-stop continuation with extension-owned background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the omp primary auto-loaded both project extensions; if not, restart omp with `-e __FM_OMP_TURNEND_EXT__ -e __FM_OMP_EXT__`.
3. First cycle only: call the `fm_watch_arm_omp` tool once.
   Never run `bin/fm-watch-arm.sh` through omp's bash tool because that foreground arm bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_omp` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live omp process, and owns every later successor launch.
6. The generation owner activates on `session_start`, replaces the active generation on `session_switch`, and retires the active generation on `session_shutdown`; stale callbacks cannot re-arm a replacement session.
   The generation-owner contract lives in `.omp/extensions/fm-primary-omp-watch.ts`.
7. After an actionable child close, the extension starts and verifies one successor before delivering the follow-up wake; its bounded fallback is extension-owned.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_omp` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_omp`, and let the extension restore continuity.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into `__FM_OMP_TURNEND_EXT__`).

The omp `session_stop` handler is awaited before the main session settles and returns `{ continue: true, additionalContext }` when `bin/fm-turnend-guard.sh` exits 2.
OMP caps consecutive native continuations at eight and never emits `session_stop` for task or subagent sessions.
The turn-end guard extension lives at `__FM_OMP_TURNEND_EXT__`.
The watcher extension lives at `__FM_OMP_EXT__`.
Both are tracked project-local `.omp/extensions/*.ts` files that omp auto-discovers from the project root.
