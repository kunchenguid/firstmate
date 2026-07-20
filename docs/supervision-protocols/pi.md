Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi`, after approving project trust once per clone); if not, restart with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. On `session_start`, the watcher extension first requires `bin/fm-primary-scope.sh` to identify a main or valid secondmate primary home, then reads ownership through `bin/fm-lock.sh ownership`.
   During `startup` and `new`, a missing or dead lock remains unchanged so the session-start nudge can require the complete initialization path; after an owned lock produces a verified ready arm, the session advances to owned-only supervision.
   During `resume`, a missing or dead lock is reacquired only through `bin/fm-lock.sh`, ownership is read again, and supervision starts only after the result is `owned`.
   During `fork` and `reload`, supervision is rebuilt only from an already-owned lock; missing, dead, live-other, malformed, and unknown states remain unchanged and fail closed.
   The established session policy remains in force for actionable successors, delayed retries, away-monitor recovery, the human command, and the model tool.
   A verified live other owner remains unchanged and the extension refuses to arm.
   Any malformed or unclassifiable lock state, failed acquisition, or post-acquisition result other than `owned` fails closed without arming.
   When `state/.afk` exists, lock recovery still completes but the extension does not start or restart a watcher because the sub-supervisor owns supervision.
   If away mode begins after the extension has armed, its direct flag monitor stops that owned arm child and suppresses direct Pi wake delivery during the handoff.
   If the AFK launch transaction rolls the flag back, the extension restores normal watcher supervision automatically.
   The extension publishes its loaded marker and permits arming only after the monitor is active, and retries monitor failures with capped exponential backoff without re-running invariant primary-scope probes.
   Recovery wake delivery is rejection-safe and cannot escape as an unhandled Pi lifecycle promise.
4. Arm the first cycle with the `fm_watch_arm_pi` tool if the extension has not already armed it during `session_start`.
   The tool returns success only after `fm-watch-arm.sh` verifies and reports a started watcher.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns every later successor launch.
6. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
7. Ordinary wake: do not call `fm_watch_arm_pi` again because continuity is extension-owned rather than model-memory-owned.
8. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
9. Failure or missing cycle only: if the extension reports `read-only`, changed, lost, or otherwise unverified session-lock ownership, remain read-only and do not drain or repair supervision.
   For other watcher failures, drain queued wakes, inspect the failure text, call `fm_watch_arm_pi`, and restart Pi with both extensions loaded if needed.
10. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.

Verification on 2026-07-09 used Pi 0.80.5, an isolated `PI_CODING_AGENT_DIR`, an isolated `FM_HOME`, and the dedicated tmux socket `fm-pi-q6-lab`.
The command `Use the fm_watch_arm_pi custom tool now. Do not use bash.` rendered `watcher: started Pi extension arm child 1`, then the model returned `DONE` without the prior `result.content.filter(...)` crash.
The extension tool returned Pi's required text `content` plus structured `details` and used `Type.Object({})` for its parameter schema.
The human command `/fm-watch-arm-pi` notified through `ctx.ui.notify(...)` and returned no value.
The clean-exit probe ran `/quit`, printed `PI_EXIT=0`, and confirmed that both the attached arm process and watcher child were gone.
That cleanup is owned by a one-shot process `exit` listener because Pi 0.80.5 did not reliably emit `session_shutdown` for `/quit`; the listener is removed when `session_shutdown` does run.
Command run for the complete interactive regression: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.80.5 live E2E rendered the tool, guarded once, woke, re-armed, and cleaned up on exit`.
Command run for the installed-type contract: `tests/fm-pi-primary-types.test.sh`.
Observed output: `ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.80.5`.

Verification on 2026-07-16 added subprocess-backed resume and lock-owner coverage without changing Pi core or global Pi installation state.
Command run: `bash tests/fm-session-lock.test.sh`.
Observed output included `ok - native Pi comm and argv are classified as a live holder`, `ok - a verified live other holder remains byte-for-byte unchanged`, and `ok - serialized concurrent contenders produce exactly one winner`.
Command run: `bash tests/fm-pi-watch-extension.test.sh`.
Observed output included `ok - Pi custom tool waits for verified watcher readiness`, `ok - Pi session_start reclaims safe locks, preserves away ownership, refuses live other, and idempotently arms`, `ok - Pi watcher stays inert in linked task worktrees and arms valid secondmate homes`, and `ok - Pi watcher distinguishes verified competitor, acquisition failure, and changed ownership`.

Verification on 2026-07-17 used native Pi 0.80.7 with a mode-0700 system temporary lab, an isolated saved session, a deterministic test-owned in-process faux provider, `PI_CODING_AGENT_DIR`, `FM_HOME`, project clone, and tmux socket.
Command run: `bash tests/fm-pi-watch-extension.test.sh`.
Observed output included `ok - Pi watcher transfers its active arm and restores rollback supervision` and `ok - Pi watcher contains delivery rejection and backs off monitor failures`.
Command run: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
The provider generated every response and tool call locally without reading global Pi authentication or making an API request.
The fixture created a saved session with `--session-id`, exited while leaving the dead native Pi PID in `.lock`, and resumed that exact session with `--session`.
At the boundary before the real watcher arm script ran, the old PID was dead and `.lock` already named the new native Pi process.
Observed output: `ok - Pi 0.80.7 live E2E created, exited, resumed, reclaimed before watcher startup, auto-started a successor, and cleaned up`.
The opt-in interactive fixture remains isolated behind `FM_PI_LIVE_E2E=1`.
