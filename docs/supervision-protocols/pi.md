Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary was launched with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__`.
3. Arm supervision by using the Pi command `/fm-watch-arm-pi` or the `fm_watch_arm_pi` tool.
4. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and sends a follow-up user message when the child exits with an actionable watcher reason.
5. If the extension says the watcher is already healthy, do not start another cycle.
6. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with both extensions loaded if needed.
7. Never use shell `&` for watcher supervision.

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The generated watcher extension lives at `__FM_PI_EXT__`.
`bin/fm-session-start.sh` creates or refreshes the generated watcher extension for Pi primaries and reports when the running Pi session has not loaded both required extensions.
