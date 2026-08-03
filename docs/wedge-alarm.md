# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because the alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
