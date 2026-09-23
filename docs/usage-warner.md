# Local Claude usage threshold warner

`bin/fm-usage-warner.sh` is an opt-in, macOS-only threshold warner for Claude
usage windows.
It is a warner, not a viewer: it never renders a live usage report, and it
speaks only once when a configured window crosses a configured percentage.

The read itself is not new.
[`quota-axi`](configuration.md) is the one Claude-quota reader this fleet
depends on, already exposing `--json`, `--full`, `--tui`, and
`--no-credential-refresh`; this script runs that exact read (through
`bin/fm-quota-axi-lib.sh`'s own provider-row join) and never re-implements it.
Every call passes `--no-credential-refresh`, so the read is strictly
read-only; the script never passes `--allow-keychain-prompt` or any other
credential-refreshing flag.

## Opt-in is load-bearing

An unconfigured home sees no behaviour change: `check` stays completely
silent, and `arm` refuses outright rather than registering a check that would
never have anything to warn about.
Nothing here makes `quota-axi` a dependency of anything beyond this one
feature.

## Configuring thresholds (config/usage-warner)

Thresholds live in `config/usage-warner`, local and gitignored; its
`<window-id>:<percent>` schema is owned by
[`configuration.md`](configuration.md#local-claude-usage-warner-configusage-warner).
`<window-id>` reuses `quota-axi`'s own `--json` `id` vocabulary - `five_hour`,
`seven_day`, `model:<name>`, and so on - rather than inventing a second one.
A configured window id the account does not return is silently never
compared: this is a local convenience feature, not a critical monitor, so a
stale or unavailable id is not treated as a misconfiguration to flag.

The two account-level windows, `five_hour` and `seven_day`, are the reliable
targets: they exist for every account regardless of what per-model windows a
given account happens to return.
See [`docs/examples/usage-warner`](examples/usage-warner) for a starting
point to copy into a local `config/usage-warner`.

## Behaviour: one read, two callers, edge-triggered

`check` is the one read with two callers - a human or another script running
`fm-usage-warner.sh check` directly (on demand), and the watcher polling the
registered shim on its normal `FM_CHECK_INTERVAL` cadence once armed
(periodic).
Both hit the identical function, so this is one program with two callers, not
two programs, and there is no daemon and no schedule of its own.

A window that crosses its configured threshold notifies once, stays quiet
while it remains at or above that threshold, and re-arms the moment it next
reads back below threshold (an account-level window's own reset does exactly
this).
Multiple windows crossing in the same read are batched into one notification
rather than one per window.
A standing read failure (`quota-axi` missing, `jq` missing, a malformed
response, or a read that does not finish inside its bound) is reported once
until it changes, the same contract
`bin/fm-mail-check.sh` and `bin/fm-tool-update-check.sh` already use for their
own standing checks.
The read bound is 10 seconds, or `FM_CHECK_TIMEOUT` minus 3 seconds when that
is lower, so the watcher never kills the check first; when that leaves under
1 second the read is skipped and reported as not measured.

## Notification path

Warnings reach macOS through Notification Center (`osascript display
notification`), the same OS-level path firstmate's own away-mode wedge alarm
resolves to on this platform
([`bin/fm-supervise-daemon.sh`](../bin/fm-supervise-daemon.sh)'s
`wedge_alarm_via_osascript`), so the home keeps one alert mechanism rather
than two.
This script does not source or call into that daemon: production only execs
the daemon, and the daemon's own library-mode guard defaults its notifier seam
to "discard" whenever it is sourced instead, specifically so a second sourcing
consumer can never fire a real notification through it.
The away-mode config schema and max-defer rate limiting are also specific to
buffered escalations, not to this feature's own edge-triggered de-dupe.
So this script posts the identical OS call under its own title instead, which
is the reusable part of "the same alerting path" without reaching into
daemon-internal, away-mode-specific state.
Notification Center is macOS-only, so `arm` refuses on any other platform.

## Arming

Arm once per home with `bin/fm-usage-warner.sh arm` and remove it with
`bin/fm-usage-warner.sh disarm`; what each writes or removes, and when `arm`
refuses, is owned by
[`configuration.md`](configuration.md#local-claude-usage-warner-configusage-warner).

## What this never does

Install, refresh, or write any credential; read or render a live usage
report; or make `quota-axi` a dependency of anything beyond this one opt-in
feature.
Account or seat switching is explicitly out of scope: only the default
account lane is ever read.
