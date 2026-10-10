# Wedge alarm

A wedge is a stall that would otherwise be invisible: something Firstmate depends on has stopped making progress while still looking alive.
The alarm is how such a stall reaches the captain.
It is pane-independent because a terminal status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.

`bin/fm-wedge-alarm-lib.sh` is the single implementation of the channels below, and every caller shares it rather than growing a second notification path.
Each caller keeps its own durable marker as the record, sets its own banner title, and decides when the alarm is warranted.

## Callers

**Away-mode injection.**
The sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises the alarm, rate-limited to at most once per max-defer window.
Its durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash remain as additional signals.

**Wedged secondmate recovery.**
`bin/fm-secondmate-liveness-lib.sh` raises the alarm whenever it SIGKILLs and relaunches a Herdr-backed secondmate whose agent was running but had stopped making progress.
That recovery is automatic and destroys the session's in-flight turn, so it is never allowed to be silent - the alarm fires on success and on a failed relaunch alike, and names the killed pids and the evidence file.
No separate rate limit applies: the alarm fires only on an actual kill, and the existing per-mate relaunch bound already caps how often that can happen.
The library's own header owns the detection contract, and [`configuration.md`](configuration.md#wedged-secondmate-recovery-configsecondmate-wedge-window) owns the window setting that governs it.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining each caller's durable marker and the away-mode tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because every caller raises the alarm only after a genuine wedge, and each one bounds how often it can repeat.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the caller.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary and the title as argv items rather than interpolated source, so neither can alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
`tests/lib.sh` defaults that seam to `discard` for every suite, so no test can accidentally post a real notification - sourcing it is unavoidable for a test, which is what makes the guarantee impossible to forget.
`bin/fm-supervise-daemon.sh` additionally applies the same default whenever the daemon itself is sourced.
`tests/wake-helpers.sh` replaces the seam with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
`tests/fm-secondmate-liveness.test.sh` covers the wedged-secondmate caller.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
