Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi`, after approving project trust once per clone); if not, restart with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. Arm supervision with the `fm_watch_arm_pi` tool.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. The extension starts `bin/fm-watch-arm.sh --restart`, validates owned supervision through the shared watcher lock-identity and beacon predicate on every repeated arm call, and sends a follow-up user message when the child exits with an actionable watcher reason.
5. If the extension says the watcher is already healthy, do not start another cycle.
6. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with both extensions loaded if needed.
7. Never use shell `&` for watcher supervision.
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

Verification on 2026-07-15 reproduced the false-health incident with two Herdr-backed task records, an isolated `FM_HOME`, an isolated `PI_CODING_AGENT_DIR`, and a fake backend CLI that never returned.
Before the fix, the native event capability command blocked beneath nested `fm-watch.sh` command-substitution shells, the beacon stopped advancing, and terminating only the arm shell left descendants holding its output pipes, so Pi's child `close` event could not clear the active reference.
The watcher now bounds both native capability probes and event waits, refreshes its beacon only while that bounded child is supervised, and terminates the exact child tree on timeout or watcher shutdown.
The Pi extension now calls `fm_watcher_healthy` for the shared live-pid, lock-identity, home, watcher-path, and beacon predicate, accepts health only when that watcher descends from its arm process, and owns a detached process group until inherited pipes close.
Command run for deterministic regressions: `tests/fm-supervision-events.test.sh && tests/fm-pi-watch-extension.test.sh`.
Observed output included `ok - event_wait_or_sleep: a hung backend probe is bounded and its exact process tree is reaped` and `ok - Pi stale child recovery checks lock+beacon health and reaps inherited-pipe descendants`.
Command run for the real lifecycle: `FM_PI_LIVE_E2E=1 FM_PI_AUTH_DIR=<existing-auth-dir> tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.80.7 live E2E rendered the tool, guarded once, woke, re-armed, and cleaned up on exit`.
Command run for strict installed declarations: `PATH=<cached-typescript-bin>:$PATH tests/fm-pi-primary-types.test.sh`.
Observed output: `ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.80.7`.
