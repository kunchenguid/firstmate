Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm Pi loaded the tracked project watcher extension.
3. A trusted plain Firstmate checkout auto-loads it, and explicitly naming the same canonical file with `-e` is safely deduplicated by Pi.
4. For an unattended firstmate or secondmate launch, use `--approve -e __FM_PI_EXT_SH__` so project resources are approved for that run and the tracked extension still resolves to one canonical source.
   Replace the Pi process from outside its composer; never submit a Pi launch command as a Pi prompt or start a nested Pi through its own Bash tool.
5. Bare `-e` does not suppress Pi's project-trust dialog.
6. The extension automatically arms supervision from Pi's bound `session_start` lifecycle.
   While `state/.afk` exists, lifecycle reconciliation stops the extension-owned arm, retains actionable wakes and failures not caused by that intentional stop without native follow-up delivery, and keeps its status offline.
   After the flag clears, the next lifecycle reconciliation delivers the retained wake before resuming normal arming.
   Use `fm_watch_arm_pi` or the human-entered `/fm-watch-arm-pi` command only as an idempotent recovery fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypass extension-owned cleanup.
7. The extension starts `bin/fm-watch-arm.sh --restart` as an owned detached process group and sends an actionable exit through Pi's custom `firstmate-watcher-wake` message with follow-up delivery and turn triggering.
   The wake is a structured custom background event rather than a user-role message.
   Once Pi accepts that native custom wake, the extension immediately starts the next arm cycle without waiting for model action or a turn-end callback.
8. One process-wide coordinator per effective `FM_HOME` owns the current arm generation.
   Duplicate factories share that coordinator, stale generation callbacks cannot clear a replacement, output capture stays bounded, and every unexpected terminal outcome records one wake for delivery.
   A failed native submission stays pending and is retried before the next arm, so it is cleared only after one successful delivery.
   Intentional session shutdown suppresses false wakes, terminates the whole arm/watcher process group with bounded TERM-to-KILL escalation, and waits for cleanup before reload or quit completes.
   The Pi footer status key `firstmate-pi-watcher` reads `offline` before startup, `watching` while the current arm owns supervision, `handling wake` after an actionable custom wake is accepted, and `attention` when ownership, startup, delivery, or an unexpected arm exit fails.
   Here, `handling wake` means Pi synchronously accepted the extension's structured custom-message submission; it does not confirm that the requested follow-up turn started.
   The automatic replacement returns it to `watching`; reload and shutdown clear the old client status so a stale generation cannot overwrite the replacement.
9. If the extension says the watcher is already healthy, do not start another cycle.
10. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with the watcher extension loaded if needed.
11. Never use shell `&` for watcher supervision.
    The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the watcher extension at `__FM_PI_EXT__`).

The watcher extension lives at `__FM_PI_EXT__`.
It is the only tracked, project-local Pi extension.
Do not install or copy it globally.
Pi deduplicates repeated canonical paths, not logical extension identities, so a distinct copied watcher registers `fm_watch_arm_pi` twice and aborts startup with a tool conflict.
`bin/fm-session-start.sh` reports when the running Pi session has not loaded the required tracked file.

The focused regression is `tests/fm-pi-watch-extension.test.sh`.
The strict installed-type contract is `tests/fm-pi-primary-types.test.sh`, pinned to Pi 0.80.6 by the test and CI setup.
The opt-in clean-stock lifecycle regression is `FM_PI_LIVE_E2E=1 FM_PI_LIVE_AUTH_FILE="$HOME/.pi/agent/auth.json" tests/fm-pi-primary-live-e2e.test.sh`.
