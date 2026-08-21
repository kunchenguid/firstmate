Mode: omp extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the omp primary loaded both extensions via `-e`; omp does NOT auto-discover project `.pi/extensions`, so both are passed explicitly at launch by `bin/fm-spawn.sh`. If the running session has not loaded both, restart omp with `-e __FM_OMP_TURNEND_EXT__ -e __FM_OMP_EXT__`.
3. First cycle only: make the one required `fm_watch_arm_omp` call.
   Use `/fm-watch-arm-omp` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through omp's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_omp` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live omp process, and owns every later successor launch.
6. Ordinary same-process session replacement (`/new`, `/resume`, `/fork`, handoff) fires `session_switch`, which retires only the prior generation; call `fm_watch_arm_omp` once for the first cycle of the replacement session without restarting omp.
   The generation-owner contract lives in `.pi/extensions/fm-primary-omp-watch.ts`.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_omp` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_omp`, and restart omp with both extensions loaded if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_OMP_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_OMP_TURNEND_EXT__`.
The watcher extension lives at `__FM_OMP_EXT__`.
Both are project-local `.pi/extensions/*.ts` files loaded explicitly via omp's `-e` flag; `bin/fm-session-start.sh` reports when the running omp session has not loaded both required extensions. omp fires `session_stop` (not Pi's `agent_settled`) when a turn is about to settle, and the guard runs there.
