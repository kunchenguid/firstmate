Mode: OMP extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`. Handle every emitted wake, open decision, and unread status line, then run the exact `WAKE_ACK_REQUIRED` command.
2. Confirm OMP loaded both project extensions from `.omp/extensions`. If not, restart `omp` from the FirstMate root or launch it with `--extension __FM_OMP_TURNEND_EXT__ --extension __FM_OMP_EXT__`.
3. First cycle only: call `fm_watch_arm_omp`. Use `/fm-watch-arm-omp` only as a human-entered fallback.
4. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the arm child attached to the live OMP process, and owns every successor launch.
5. After an actionable close, the extension verifies the successor and confirms handling delivery before it sends the follow-up wake.
6. Ordinary work, turn completion, and ordinary signal, stale, check, or heartbeat handling never require another arm call. Continuity is extension-owned.
7. A missing, failed, or unhealthy cycle is repaired with `fm_watch_arm_omp`. If the session lock is gone, run `bin/fm-session-start.sh` first.
8. `session_stop` runs the turn-end guard before OMP settles. A missing watcher blocks settlement through OMP's native continuation path, under FirstMate's existing bounded guard.
9. When `.afk` exists, away mode remains the primary supervisor. Do not start a competing normal supervision cycle.
10. Never use shell `&` for watcher supervision. The watcher-arm and `cd` pre-tool guards block unsafe shell paths before execution.

The turn-end guard extension lives at `__FM_OMP_TURNEND_EXT__`.
The watcher extension lives at `__FM_OMP_EXT__`.
Both are tracked project-local `.omp/extensions/*.ts` files. OMP auto-discovers them when launched from the FirstMate root. Workers and secondmates receive explicit `--extension` paths.
