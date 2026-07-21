Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi`, after approving project trust once per clone); if not, restart with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. First cycle: arm with the `fm_watch_arm_pi` tool.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pi` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns every later successor launch.
6. On `/new`, `/resume`, `/fork`, or `/reload`, `session_shutdown` invalidates the old logical session, cancels its retry state, and signals its child to stop before the matching `session_start` restores clean arm state and one process-exit cleanup listener.
   A real `quit` or process exit never creates that pending replacement, so a late callback cannot restart supervision during shutdown.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary wake: do not call `fm_watch_arm_pi` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Failure or missing cycle only: if the extension reports a watcher failure, drain queued wakes, inspect the failure text, call `fm_watch_arm_pi`, and restart Pi with both extensions loaded if needed.
11. Never use shell `&` for watcher supervision.
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

Continuity verification on 2026-07-17 used Pi 0.80.10 with the existing shared Pi credential store and the explicit `openai-codex/gpt-5.6-sol` provider/model pin.
The isolated live test copied no credential material and created no account.
The model called `fm_watch_arm_pi` exactly once, an actionable status closed that cycle, the extension ledger-linked a verified successor before the handling turn ended, the turn-end guard never fired, and `/quit` cleaned up both child processes.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Logical-session replacement verification on 2026-07-20 used Pi 0.80.10, an isolated `PI_CODING_AGENT_DIR`, an isolated `FM_HOME`, and a unique tmux socket.
The launch shape was `env PI_CODING_AGENT_DIR="$LAB/pi-agent" FM_HOME="$LAB/fmhome" FM_ROOT_OVERRIDE="$LAB/project" pi --offline --approve --no-session --no-context-files --no-extensions --no-skills --no-prompt-templates -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts`.
The interactive sequence was `/fm-watch-arm-pi`, `/new`, `/fm-watch-arm-pi`, `/new`, `/fm-watch-arm-pi`, and `/quit`.
Before the fix, the second arm rendered `Warning: watcher: not armed - Pi session is shutting down` even though Pi had rendered `New session started`.
After the fix, each old arm and watcher exited with ledger reason `arm-interrupted`, each new watcher published a new identity-matched lock PID and fresh readiness beacon, and the final `/quit` left no arm or watcher child alive.
Command: `FM_PI_SESSION_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.80.10 isolated live E2E re-armed after two /new commands and cleaned up on exit`.
Command: `tests/fm-pi-watch-extension.test.sh`.
Relevant observed output: `ok - Pi session replacement resets supervision while real shutdown stays terminal`.
