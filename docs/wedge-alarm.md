# Away-mode injection wedge alarm - active alert channels

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into firstmate's own pane.
When injection cannot deliver past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The cause is whatever `inject_msg` last recorded, and it is not always a busy pane: the supervisor's agent may have exited to a shell or be unverifiable on this backend (`agent-dead` / `agent-unknown`, from the fail-closed agent-liveness guard), a human's text may be sitting in the composer (`composer-not-empty`), the pane may be mid-turn (`pane-busy`), or the submit's Enter may have been swallowed (`submit-unconfirmed`).
One cause comes from the daemon's main loop rather than an inject attempt: when the supervisor pane itself has not resolved for a full max-defer window (`pane-gone`), there is nowhere to attempt a delivery at all, so `pane_gone_wedge_alarm` records the vanished pane and raises the same alarm from the backoff path - the active alert below needs no pane, which is exactly why it is the channel that survives this.
The alarm carries that cause tag in its active alert and status-line flash, and the full detail in the ERROR log line and a durable marker, so a wedge never has to be diagnosed by guesswork.

Each of the two alarms owns its own marker, and may only ever retire its own: the buffer wedge writes `state/.subsuper-inject-wedged`, cleared by a successful flush, and the vanished pane writes `state/.subsuper-pane-gone`, cleared when the target resolves again.
They shared one file until 2026-07-14, and a pane-gone alarm therefore rewrote a composer wedge's record as its own and then deleted it on recovery - discarding the one marker whose contract says leave it for a successful flush to clear, while the buffer it described was still undelivered.

`pane-gone` is the one cause whose captain-facing wording is not about the buffer, because it is not a queue stuck behind a busy pane: away-mode supervision is DOWN and nothing can be delivered, buffered or not.
It also fires on an EMPTY buffer, deliberately unlike the max-defer alarm, which is gated on buffered content.
The buffer cannot even grow while the pane is gone - the main loop's backoff never reaches the wake handling that buffers - so an empty buffer is the ordinary case, and a buffer gate here would restore exactly the away-window silence this alarm exists to end.
Every channel therefore says supervision is down and states the buffered count, rather than claiming undelivered escalations that may not exist.
It also alarms ONCE per absence episode, latched in `pane_gone_wedge_alarm` rather than re-thrown each window like the other causes.
Their throttles re-open after a max-defer window because those conditions are re-tested and can heal - a busy composer clears, a flush lands - so a repeat is a progress report.
A vanished pane heals only when the pane comes back, and the target is usually a unique pane id, so the same throttle would re-push the active alert every window for the life of the daemon: a terminal that dies at 23:30 buys the captain ~96 banners and ~96 pushes through a configured `command:` channel by morning, none of them actionable from away.
Alert fatigue on the one channel that has to work is the failure this alarm exists to prevent, so only the re-pushing stops; the durable marker and the ERROR log remain the record.

`pane_gone_recovered` retires that marker the moment the target resolves again, and re-arms the latch for the next episode: nothing else would clear it, since a pane-gone alarm fires whether or not anything is buffered.
Targets are usually names rather than unique pane ids (`FM_SUPERVISOR_TARGET_DEFAULT` is `firstmate:0`), so a window killed and recreated resolves again, and without that recovery edge firstmate's afk-exit catch-up would report a wedge that healed hours earlier against a pane that is now healthy.
Separate marker files are what make that safe: the recovery edge can only ever delete the file this alarm writes, so a pane blinking out and back can never take a composer wedge's record with it.

## Reach: what is guaranteed, and what is best-effort

The two failures the fail-closed liveness guard leaves behind do not have the same reach, and the difference matters when reading an alert - or its absence.

**Agent dead, pane alive** (`agent-dead` / `agent-unknown`: firstmate exited to a shell, or its harness is unattributable on this backend) is robustly reported.
The pane still resolves, so the daemon's main loop keeps reaching housekeeping, and the max-defer alarm re-raises once per window until the buffer is delivered - a failed push is effectively retried on the next window.

**Pane gone** is BEST-EFFORT, and is the weaker of the two on purpose (see the follow-ups below).
The main loop's pane-gone backoff never reaches housekeeping, so the alarm is raised from the backoff path itself, latched to one alert per absence episode.
`wedge_alarm_notify` is best-effort by contract - it always returns 0 and reports no per-channel success - so the single push that latch permits cannot be confirmed, and a transient failure (a network blip on a `command:` channel, an `osascript` timeout under load) loses the alert for the rest of the away window.
The durable marker and the ERROR log survive it, but both are read only once the captain is back.
Making it self-retrying without recreating the all-night repeat needs either a delivered-alert signal out of `wedge_alarm_notify` or a bounded re-fire; that is a deliberate follow-up, not shipped here.

## Known follow-ups

- **Bounded re-fire of the pane-gone alert**, so it is both non-spammy and self-retrying: latch on a DELIVERED alert rather than an attempted one, or allow a small bounded number of re-pushes per absence episode.
- **`fm_afk_canary_daemon_endpoint` races the endpoint publish**: it collapses "no live daemon" and "a live daemon that has not published its endpoint yet" into one answer, so a fresh arm can print the fresh-arm remediation where the stop-then-arm one is correct.
- **The `gone` verdict comes from a single unretried existence probe**, so a flaky backend read (herdr's `pane get` is one bare RPC) is indistinguishable from a vanished pane; the retry, or a backend-reachability check that degrades to `unknown`, belongs in the same resolver.

## Why an active channel beyond the status-line flash

Before this change the only ACTIVE signal `inject_wedge_alarm` sent was a tmux `display-message` status-line flash, guarded by `if [ "$backend" = tmux ]`.
That flash is a client-side OSD with no cross-backend equivalent, so on every non-tmux supervisor backend it was skipped entirely.
On 2026-07-10 a `claude`-on-`herdr` primary wedged past max-defer overnight: the tmux flash was skipped, and only the passive `state/.subsuper-inject-wedged` marker was written.
Nothing surfaces that marker until the next fleet action, so 20 escalations sat buffered for roughly 8.5 hours with no active alert.
The classifier-side half of that incident shipped separately (PR #429); this is the alarm-channel half.

`inject_wedge_alarm` now also calls `wedge_alarm_notify`, a configurable active alert that does not depend on any pane or its backend status-line.
The durable marker and the tmux flash are unchanged; the active alert is added alongside them.

## Channels

`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive (used by the tests).

- `off` - position-independent kill switch that disables every active alert; the marker and tmux flash remain.
- `auto` / `default` - platform default. macOS resolves to `osascript`; other platforms have no built-in OS channel, so `auto` there fires nothing and logs that the durable marker is the only signal (configure a `command:` directive instead).
- `osascript` - a macOS Notification Center banner via `osascript`. OS-level, so it reaches the captain even when every pane and its status-line is unreadable.
- `herdr` - a herdr UI notification via `herdr notification show`. herdr's own surface, separate from the pane and its status-line.
- `command:<cmd>` - run `<cmd>` via `sh -c`, with the alarm summary passed as `$1` and on stdin. Lets the alert reach a phone or pager (ntfy, Slack, SMS) even when the captain is away from the machine entirely.

An absent `config/wedge-alarm` behaves as `auto`, i.e. default-on on macOS.
Default-on is deliberate: the alarm's entire purpose is that a wedged away-mode primary is never silent, so the reachable OS channel fires unless the captain explicitly disables it.
The alarm is rate-limited to at most once per max-defer window, and fires only after a genuine wedge past max-defer, so the default-on banner is rare and never chatty.

Each channel is best-effort: a missing binary or a non-zero exit logs a warning and the alarm falls through to the next channel, never crashing the daemon loop.
Every invocation is also process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS` (10 seconds by default), including `command:`, `osascript`, `herdr`, and an `FM_WEDGE_ALARM_EXEC` override.
On timeout or daemon shutdown, its watchdog terminates the notifier group, logs the timeout when applicable, and continues to the next configured channel.
The AppleScript passes the summary as an `argv` item rather than interpolating it into the script source, so summary text can never break the notification.
See `docs/examples/wedge-alarm` for a copyable starting config.

## Test safety: no test posts a real notification

Every notifier channel (`osascript`, `herdr`, and `command:`) routes through a single seam, `FM_WEDGE_ALARM_EXEC`: when it is set, the daemon hands the fixed channel category and summary to that command instead of the real notifier (`wedge_alarm_emit` in `bin/fm-supervise-daemon.sh`).
This makes it structurally impossible for a test to post a real desktop notification, and impossible for a future test author to forget to stub:

- The daemon is only ever sourced (not executed) by tests - production `bin/fm-afk-start.sh` execs it.
  Whenever the daemon is sourced, its library-mode guard defaults `FM_WEDGE_ALARM_EXEC` to `discard`, which fires nothing.
  A real daemon a test later spawns inherits that default through the environment.
- `tests/wake-helpers.sh` upgrades the default to an on-disk recorder that logs `<channel>\t<summary>` to `$FM_WEDGE_ALARM_LOG`, so the daemon and wake suites can assert channel selection without any real notifier.
- Production leaves `FM_WEDGE_ALARM_EXEC` unset, so the real channels fire.

Because of this seam, the automated tests verify channel selection and summary propagation only.
The real `osascript`/`herdr` invocation form is verified once by the single bounded manual run below, never from a suite.

## Verification (macOS, darwin)

Recorded 2026-07-10T12:41-0700 on macOS 26.5.2 (build 25F84), `osascript` at `/usr/bin/osascript`, `herdr` 0.7.3.
This is the single bounded manual verification (two invocations, one per OS channel), labelled "FIRSTMATE TEST - IGNORE" so the banners are unmistakably harmless.
These are the only verification commands that fire real notifications, and they are never run inside a test suite.

### osascript channel (the exact argv-safe form the daemon runs)

```
$ /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name "Basso"' \
    -e 'end run' "FIRSTMATE TEST - IGNORE (wedge-alarm title argv verification)" "FIRSTMATE TEST - IGNORE"
$ echo $?
0
```

Exit 0; a Notification Center banner titled "FIRSTMATE TEST - IGNORE" was posted with the label as its body.
The title is an argv item like the body, never interpolated into the AppleScript source, because it is no longer a constant: it follows the cause.
In production a refused injection posts "firstmate: away-mode escalations WEDGED" over the `<age>s undelivered (<cause>) - see <marker>` summary, and a vanished pane posts "firstmate: away-mode supervision DOWN" over its own summary.
A banner's title is often all a truncated notification shows, so a vanished pane must not be titled as a queue of stuck escalations (re-verified 2026-07-14 in the argv form above; the herdr channel's title is a plain argument and needed no re-verification).

### herdr channel

```
$ herdr notification show "FIRSTMATE TEST - IGNORE" \
    --body "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)" --sound request
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
$ echo $?
0
```

Exit 0; herdr reported `"shown":true`.
The daemon redirects this stdout to `/dev/null` and treats a zero exit as success.

### command channel dispatch (summary on $1 and stdin)

The `command:` channel runs `sh -c "<cmd>" fm-wedge-alarm "<summary>"` with the summary also piped on stdin.
`test_wedge_alarm_command_channel_receives_summary` deliberately unsets the seam for a safe file-writing command to verify this dispatch contract without a notification.
