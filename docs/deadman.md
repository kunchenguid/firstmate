# Studio deadman

The Studio deadman is one notify-only macOS LaunchAgent that detects loss of Firstmate's watcher and scheduling path.
It runs a stable installed copy outside the git checkout and never starts, stops, repairs, dispatches, merges, publishes, or changes fleet work.

## Guarantee

The probe reads one configured `FM_HOME` and checks only `state/.last-watcher-beat`.
A beacon age greater than 600 seconds is unhealthy by default.
A missing or unreadable home or beacon and a beacon timestamp in the future are also unhealthy.
The deadman pages only after the same unhealthy class is observed twice, with the observations 60 to 120 seconds apart.
The first installation window defaults to 660 seconds of grace, and a run gap greater than 180 seconds starts a 300-second sleep/wake grace before paging.
A healthy observation clears an unfinished stale confirmation.

Successful pages are rate-limited for 30 minutes by default.
A failed notification does not update the successful-page cooldown and is eligible for retry after another valid unhealthy confirmation sample.
Deadman configuration, cooldown state, confirmation state, and its bounded journal live under `~/Library/Application Support/Firstmate/deadman/`, outside the monitored home.
The LaunchAgent runs that installed probe every 60 seconds.

This is a watcher and scheduling-path guarantee, not proof that the entire Firstmate primary session is healthy.
Version 1 does not check Tailscale, SSH port 2222, multiple Firstmate homes, product clocks, or phone-provider SDKs.
It never restarts the watcher or any other service.

## Notification channels

`deadman.conf` uses the shared Firstmate notification grammar owned by `bin/fm-notify-lib.sh`, with one directive per non-empty, non-comment line.
The supported directives are `off`, `auto` or `default`, `osascript`, `herdr`, and `command:<cmd>`.
`auto` selects macOS Notification Center through `osascript` and has no built-in channel on other platforms.
Every configured non-`off` channel is attempted, so a `command:` phone path can accompany Notification Center as a secondary channel.
The notification summary is passed to `command:` as `$1` and on standard input.
Treat a `command:` value as executable shell configuration and keep `deadman.conf` readable only by the account that runs the agent.

## Install

Run the installer from the trusted Firstmate checkout and pass the operational home explicitly when it differs from that checkout.

```bash
bin/fm-deadman-install.sh \
  --fm-home /absolute/path/to/firstmate-home \
  --channel osascript \
  --channel 'command:your-phone-notifier "$1"'
```

The installer atomically copies `fm-deadman.sh` and `fm-notify-lib.sh` into `~/Library/Application Support/Firstmate/deadman/`, writes `~/Library/LaunchAgents/com.firstmate.deadman.plist`, and sends a mandatory canary notification.
Without `--bootstrap`, it does not load the LaunchAgent.
Confirm the canary arrived, then run the same command with `--bootstrap` to send a fresh canary and load the agent.

```bash
bin/fm-deadman-install.sh \
  --fm-home /absolute/path/to/firstmate-home \
  --channel osascript \
  --channel 'command:your-phone-notifier "$1"' \
  --bootstrap
```

If the canary fails, the installer exits without bootstrapping launchd.
The LaunchAgent always executes the installed script path, so later checkout changes cannot silently change a running deadman.
`deadman.env` accepts only these keys; unknown keys and invalid values are self-faults:

- `FM_HOME` - absolute path of the single monitored Firstmate home
- `STALE_AFTER_SECS` - beacon age threshold in seconds; default `600`
- `SAMPLE_GAP_SECS` - minimum seconds between the two unhealthy observations; default `60`, allowed range `60`-`120`
- `SAMPLE_MAX_GAP_SECS` - maximum seconds between those observations; default `120`, must be between `SAMPLE_GAP_SECS` and `120`
- `FIRST_ARM_GRACE_SECS` - first-install grace before an armed unhealthy path may page; default `660`
- `WAKE_GRACE_SECS` - grace after a detected sleep/wake run gap; default `300`
- `SLEEP_GAP_DETECT_SECS` - run-gap size that starts wake grace; default `180`
- `COOLDOWN_SECS` - successful-page rate limit; default `1800`

An update preserves the existing deadman configuration unless `--fm-home` is supplied, in which case only that key is replaced and the timing values remain intact.
Edit `deadman.conf` to change channels without reinstalling, or pass all desired `--channel` values on the next install.

After installation, verify four operator cases manually: the canary arrives, a healthy watcher stays silent, a stopped watcher pages after the stale threshold and confirmation sample, and waking the Studio does not page during grace.

## Uninstall

The uninstall operation unloads the LaunchAgent when present, removes the plist, and removes the known installed deadman files and state.

```bash
bin/fm-deadman-install.sh --uninstall
```

## Exit behavior and logs

Normal healthy and unhealthy probes exit zero, including an unhealthy probe whose notification delivery failed and a probe skipped because another invocation holds the lock.
`--canary` exits zero only when at least one notification channel reports success.
It exits one when delivery fails or another invocation holds the probe lock.
Invalid configuration, missing installed components, and corrupt deadman-owned state exit two as self-faults for launchd diagnostics.
The bounded journal is `deadman.journal`, and launchd standard output and error logs are stored beside it.

The source behavior is covered by `tests/fm-deadman.test.sh`, including age boundaries, confirmation timing, cooldown, flaps, hostile configuration, failed delivery, concurrent invocation, no-spawn behavior, installation, and plist linting.
