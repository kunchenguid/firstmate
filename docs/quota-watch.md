# Quota watch

`bin/fm-quota-watch.sh` pauses this home's live crew when Claude usage runs
high and resumes them once it recovers, without ever spending quota itself to
do the checking.

## Why a cron/launchd script, not `schedule` or `loop`

The `schedule` and `loop` skills both dispatch a real cloud/model turn on every
firing, which is exactly the recurring cost this feature exists to avoid.
`fm-quota-watch.sh` is a plain shell script with no model call anywhere in it:
each run is `quota-axi --json` (a data-only CLI query), a few file reads/writes
under this home's own `state/`, and `bin/fm-send.sh` key/text delivery to
already-running crewmate panes.
It is meant to be triggered by the operating system's own scheduler - `cron` or
`launchd` - on a short interval, so a crossing is caught quickly without a
captain or an agent needing to be present.

## What it does

Once per invocation: read Claude's current usage, take the highest
`percentUsed` across the rate-limit-style windows only (`kind` `session` and
`weekly`), and act:

- **At or above the pause threshold** (default 80%): interrupt every live
  `kind=ship`/`kind=scout` crewmate of this home with its harness's verified
  interrupt key, send it nothing further, and record the pause both durably
  (`state/.quota-paused`) and on the crew's own status log using the existing
  `paused: <reason>` verb (`AGENTS.md` section 8, `bin/fm-classify-lib.sh`).
  A `kind=secondmate` is never touched - it has its own lifecycle.
- **Below the resume threshold** (default 65%, deliberately lower than the
  pause threshold so a reading oscillating near 80% does not flap crew back
  and forth): send one short note to every crewmate this script paused and
  clear the flag. A crewmate that declared its own unrelated `paused:` wait is
  left alone - only crew recorded in `state/.quota-paused` are resumed.
- **Between the two thresholds, or below the pause threshold with nothing
  paused**: no-op.
- **No usable reading** - `quota-axi` missing, `auth_required`, or malformed
  output - is always a harmless no-op, never a pause and never a hang.

Rerunning while still above the pause threshold does not resend interrupts or
duplicate the flag; it only picks up crew spawned since the last pause.

## Why the credits window is ignored

`quota-axi`'s claude reading reports three window kinds: `session` (the
multi-hour rate limit), `weekly`, and `credits` (paid overage spend, tracked
separately from the free session/weekly allowance).
Only `session` and `weekly` drive the pause/resume decision.
The `credits` window measures money spent, not the free allowance this script
exists to conserve - pausing crew because paid credits are high would work
against the actual goal of using the free session/weekly quota as fully as
possible, so a high `credits` reading alone never pauses anything and a still-high
`credits` reading never blocks a resume once `session`/`weekly` recover.
If neither `session` nor `weekly` is present in a reading, that is treated the
same as no usable reading at all (see below) rather than falling back to
`credits`.

## Why no separate supervision code was needed

Pausing works entirely through the vocabulary supervision already understands:
appending `paused: <reason>` to a crew's status log is the same declared
external-wait verb any crew or firstmate itself already uses for a known
bounded wait.
`bin/fm-crew-state.sh` re-reads the live pane/run-step before ever trusting
that status line, so a crew that resumed and started working again reports
`working`, never `paused` - the mechanism cannot go stale once quota recovers
and this script sends the resume note.
No new field was added to `AGENTS.md`.

## Configuration

Env wins, then a local gitignored `config/` file (first non-empty,
non-comment line), then the default:

| Setting | Env | Config file | Default |
|---|---|---|---|
| Pause threshold | `FM_QUOTA_PAUSE_THRESHOLD` | `config/quota-pause-threshold` | 80 |
| Resume threshold | `FM_QUOTA_RESUME_THRESHOLD` | `config/quota-resume-threshold` | 65 |

Both accept a bare integer 0-100.
An invalid value, or a resume threshold that is not strictly below the pause
threshold, falls back to the defaults with a stderr warning.

Run `bin/fm-quota-watch.sh --status` at any time to print the resolved
thresholds and current reading without taking any action - useful for
confirming a fresh install before waiting for a real threshold crossing.

## Installing the schedule (opt-in, one-time, per machine)

Nothing in this repo installs a cron job or launchd agent on its own - merging
or pulling firstmate changes nothing about your machine's scheduler.
Run `bin/fm-quota-watch-install.sh` yourself once to see the exact line, or add
`--install-crontab` to append it directly (idempotent: it refuses if an entry
for this script is already present).
It resolves `quota-axi` to an absolute path and bakes an explicit `PATH` into
the generated entry, because both `cron` and `launchd` run with a minimal
`PATH` that will not see a Node version manager's install directory on its own.

```sh
bin/fm-quota-watch-install.sh                    # print a crontab line
bin/fm-quota-watch-install.sh --install-crontab  # append it for the current user
bin/fm-quota-watch-install.sh --launchd          # print a launchd plist instead
```

A 5-minute default cadence is frequent enough to catch a crossing quickly
relative to the shortest quota window (the multi-hour session window) without
meaningfully adding to system load; `--interval-minutes` overrides it.
If your session backend needs its own CLI on `PATH` (`tmux`, `herdr`,
`zellij`, ...), extend the printed `PATH` value the same way before installing
it, since `fm-quota-watch.sh` calls `bin/fm-send.sh`, which dispatches through
that backend.

`quota-axi` itself needs Claude auth once per machine: if `--status` (or a
real run) reports no usable reading and `quota-axi --json` shows
`auth_required` for the `claude` provider, run `quota-axi
--allow-keychain-prompt` once yourself and approve Keychain access; the watcher
never attempts this on its own, since an unattended script prompting for
Keychain access on every cron firing would be worse than the problem it
solves.

## Tests

`tests/fm-quota-watch.test.sh` covers crossing the pause threshold, idempotent
reruns, picking up crew spawned mid-pause, the hysteresis band, recovery,
`auth_required`/missing-tool/unknown-harness no-ops, `--status`, and a high
`credits` reading never driving a pause or blocking a resume while
`session`/`weekly` stay low, all against fixture quota JSON and a fake sender -
no real quota reading, backend, or live fleet involved.
