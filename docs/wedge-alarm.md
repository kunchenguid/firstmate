# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

## When a delivery stays buffered

Away-mode delivery requires an idle primary and an affirmatively empty composer.
`pane_is_busy` refuses a primary mid-turn, and `fm_backend_composer_state` refuses any composer verdict other than `empty`, so a digest cannot merge into active or uncertain input.
If the primary remains continuously busy, buffered delivery starves by design rather than interrupting that turn.
The overnight Claude/Herdr native-path incident recorded 2,063 consecutive `inject deferred: supervisor pane busy (agent mid-turn)` deferrals, one composer deferral, zero deliveries, and roughly eight hours of starvation while the primary was genuinely idle.
Target resolution was correct: with `HERDR_SESSION` unset, supervisor discovery composed `default:<HERDR_PANE_ID>` as designed.
Claude Stop auto-arm was not the source because it exits while `state/.afk` exists.
The busy guard queries Herdr native agent state before its harness-scoped rendered-footer fallback, and the observed `3 shells still running` idle screen is not a Claude delivery busy signature.
The native background job itself holds the target's native agent state `working` for its lifetime, so same-target native hosting cannot deliver by construction.
That is a hosting limitation, not a reason to weaken the guard: launch through `bin/fm-afk-launch.sh start` so the daemon runs in its own non-visible workspace with an explicit target.
`FM_MAX_DEFER_SECS` bounds how long that deferral can remain silent: once the threshold is reached, it raises this alarm and preserves the buffered escalation.
Treat the alarm as a visible delivery failure, not as permission to override either guard.

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
