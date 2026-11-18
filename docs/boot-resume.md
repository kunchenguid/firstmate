# Boot resume: firstmate returns after a WSL restart

Firstmate homes survive a WSL restart or crash unattended: when the WSL VM
comes back, the primary firstmate session, the secondmates, and the recorded
workers return without captain action. This page owns the operator contract:
what runs, the gates, how to install and enable it, how to rehearse it, the
exact Windows-side keepalive steps (the one captain action), and what only a
real reboot can prove.

Ownership map: `bin/fm-boot-resume-lib.sh` owns the decision surface (gates,
pane resolution, restore, fallback, budgets); `bin/fm-boot-resume.sh` is the
boot entry; `bin/fm-watchdog-beat.sh` is the recurring watchdog tick;
`bin/fm-boot-resume-install.sh` renders and installs the systemd user units.
[Watcher continuity](watcher-continuity.md) owns the watcher chain this rides
on, and the away contract and goal remain their own owners.

## What happens on boot

1. `firstmate-boot-resume.service` (a systemd user oneshot, wanted by
   `default.target` and soft-ordered after the herdr bucket unit) runs
   `bin/fm-boot-resume.sh`.
2. The gates run in order; any refusal is a typed log line and a clean exit:
   - **Kill switch**: `config/boot-resume-off` present → skip.
   - **Posture**: an away record stands (`bin/fm-afk-contract.sh mode` prints
     `away`) or a goal is active (`bin/fm-goal.sh active`). Quiet mode is not
     a resume posture; a present captain needs nothing restored.
   - **Boot idempotence**: `state/.boot-resume-boot` already holds this
     `/proc/sys/kernel/random/boot_id` → already handled this boot.
3. The primary restore runs THROUGH the primary, never around it:
   - It resolves the pane herdr's reboot restore left behind: the exact
     conversation id recorded in `state/.lock-session` matched against
     herdr's per-pane `agent_session.value` in the home's own cwd. An
     ambiguous or missing match is a typed refusal, never a guess.
   - It starts the same conversation in that pane
     (`herdr agent start firstmate --kind claude --pane <pane> --timeout
     120000 -- --dangerously-skip-permissions [config words]
     --resume <session-id>`) and submits one standing recovery prompt.
   - The restored primary's own hooks then re-establish everything else:
     SessionStart runs the locked session-start sweeps (secondmate liveness
     included) and the wake-queue drain; the Stop hook re-arms the watcher.
     Recorded workers are recovered by the primary's judgment
     (stuck-crewmate-recovery, fm-control relaunch, fresh dispatch receipts),
     never by a blind script relaunch.
4. Only if the primary restore fails does a fallback secondmate sweep run,
   reusing the shared recovery contract verbatim: only `dead`/`missing`
   probe verdicts authorize a relaunch, per-mate liveness locks serialize
   against every other sweep, and the watcher's own relaunch bounds are
   honored.
5. Every restore/nudge attempt appends to `state/.boot-resume-attempts`; more
   than 2 outcomes of one kind inside 3600s parks that kind in
   `state/.boot-resume-parked-<kind>` and leaves exactly one durable inbox
   note. A parked kind retries only after the window passes or the marker is
   removed, so a boot loop can never spend an unbounded budget or spam the
   inbox.

All actions land in the bounded `state/boot-resume.log` (every line carries
the boot id). `bin/fm-boot-resume.sh --check` prints the gate verdicts and
the resolved primary pane without changing anything.

## The watcher-beat watchdog

`firstmate-watchdog-beat.timer` (5-minute cadence, first tick 3 minutes after
boot) runs `bin/fm-watchdog-beat.sh`, which watches for the failure mode
where everything booted fine but the watcher itself went silent:

- **Healthy** (live identity-matched watcher pid with a fresh
  `state/.last-watcher-beat` beacon): exit silently, touch nothing.
- **Silent watcher, live primary**: one standing nudge prompt into the
  primary's pane plus one idempotent inbox note. The primary re-arms per
  [watcher continuity](watcher-continuity.md); its arm owns stalled-holder
  eviction. A rejected nudge (agent busy) is not retried inside the tick.
- **Silent watcher, no live primary**: run the guarded primary restore; its
  hook chain brings the rest back with it.

The same kill switch, posture gate, attempt budget, and park markers bound the
watchdog, and it uses the same inbox note discipline (idempotent by
request id).

## Install and enable

From a firstmate checkout:

```sh
bin/fm-boot-resume-install.sh            # render + install units, do NOT enable
bin/fm-boot-resume-install.sh --enable   # install, daemon-reload, enable unit + timer
bin/fm-boot-resume-install.sh --print    # review the rendered units only
```

The installer bakes absolute paths (home, scripts, your `PATH`) into the
units, the same shape the herdr bucket units use, because a user manager
gives no other reliable way to pass a per-instance home. Re-running it after
a firstmate update refreshes the same unit files. Options:
`--home <dir>` (default: the checkout), `--herdr-session <name>` (the boot
unit's soft `After=`, default `personal`; a missing unit is not an error —
the script's own bounded readiness probe owns the wait), `--units-dir <dir>`.
Units are never enabled unless `--enable` is passed.

Verify after enabling:

```sh
systemctl --user list-timers 'firstmate-*'
systemctl --user status firstmate-boot-resume.service
journalctl --user -u firstmate-boot-resume.service -b
```

The one-command enable on a home whose units were installed without enabling:

```sh
systemctl --user daemon-reload && systemctl --user enable firstmate-boot-resume.service && systemctl --user enable --now firstmate-watchdog-beat.timer
```

## Kill switch and knobs

- `config/boot-resume-off` — the kill switch; present means both the boot
  resume and the watchdog become typed no-ops.
- `config/boot-resume-primary-args` — extra words for the restored primary's
  argv (one shell word per line, `#` comments allowed), for example
  `--model sonnet` and `--effort high`.
- `config/boot-resume-herdr-session` — pin the herdr session to search
  instead of every running session.
- Environment overrides for tight situations:
  `FM_BOOT_RESUME_HERDR_WAIT_SECS` (default 120),
  `FM_BOOT_RESUME_ATTEMPT_MAX` (2), `FM_BOOT_RESUME_ATTEMPT_WINDOW` (3600),
  `FM_WATCHDOG_BEAT_STALE_SECS` (600, matches the watcher beacon bound).

## The Windows keepalive (captain action)

The WSL VM shuts down ~60 seconds after the last Windows-side client closes
it, which would silently defeat boot resume while the workstation is
unattended. Keeping the VM alive is a Windows-side, elevated, one-time
captain action — firstmate never administers the Windows host. Exact steps,
once, in an elevated PowerShell:

```powershell
# Keep WSL running across the night by touching it every 5 minutes while the
# workstation is on. Adjust the distro path if `wsl.exe -l -v` shows another.
schtasks /Create /TN "FirstmateWSLKeepalive" /SC MINUTE /MO 5 `
  /TR "wsl.exe -d Ubuntu --exec /bin/true" /RU SYSTEM /F /RL HIGHEST
schtasks /Query /TN "FirstmateWSLKeepalive" /V   # verify it exists and is Ready
```

To retire it: `schtasks /Delete /TN "FirstmateWSLKeepalive" /F` (elevated).
This keeps the VM up while Windows runs; it is deliberately not a hibernate
or sleep policy — the workstation's own power settings stay the owner of
when the machine sleeps.

## Rehearsal (no reboot needed)

On a scratch home (or the real one while you watch):

```sh
# 1. Prove the gates and pane resolution read-only:
bin/fm-boot-resume.sh --check

# 2. Prove the full ladder against a dead lock: stop the primary harness and
#    the watcher (or point FM_HOME at a scratch home with a copied state),
#    then run the boot script by hand and read its typed lines:
bin/fm-boot-resume.sh
tail -20 <home>/state/boot-resume.log

# 3. Prove the watchdog paths:
bin/fm-watchdog-beat.sh --check          # verdicts only
# with the watcher stopped and beacon aged past FM_WATCHDOG_BEAT_STALE_SECS:
bin/fm-watchdog-beat.sh                  # should restore or nudge, then park
```

`tests/fm-boot-resume.test.sh` (run via `bin/fm-test-run.sh`) is the
automated version of this rehearsal: gates, idempotence, pane match and
ambiguity refusal, argv and prompt, budgets and park markers, fallback sweep
guards, all three watchdog paths against a real watcher-lock fixture, and
the installer's rendered units.

## What only a real reboot can prove

These live behind the WSL boot path and cannot be honestly verified from
inside a running session; the first real unattended restart is their proof
run (the boot-resume log and the journal are the evidence to read after):

- systemd actually runs the boot unit on the WSL VM's fresh boot (user
  manager up, `default.target` wants it) and the watchdog timer's
  `OnBootSec`/`Persistent` behavior across that boot.
- herdr's own reboot restore really leaves the recorded pane behind in the
  state this matcher expects, and the pane is at an interactive shell ready
  for `agent start` at that moment.
- The Windows keepalive actually holds the VM up across the unattended
  window (a rehearsal only proves the task exists, not that it runs while
  locked).
- The whole chain's timing under real boot load: herdr start latency inside
  the bounded wait, agent start readiness inside its timeout, and the
  watchdog's first tick landing after the beacon is honestly stale.
