# Fleet liveness guardian

`bin/fm-liveness-guardian.sh` is a session-independent supervision backstop that runs from a systemd user timer, below every session, and keeps each firstmate home's watcher alive so tasks keep being handled without a human noticing a lapse.

Read the script header and `bin/fm-liveness-guardian.sh --help` for the exact flags, environment knobs, and paths.
This page owns the mechanism, the classification matrix, the boundary, the install step, and how to verify it live.

## Why it exists

Each home's watcher (`bin/fm-watch.sh`) is kept armed by a harness-owned continuity mechanism that depends on a live session in that home: Claude's Stop auto-arm, Cursor's stop park, the Pi/OpenCode extensions, or a persistent tracked arm ([`watcher-continuity.md`](watcher-continuity.md)).
When a director's session stops taking turns while its armed watcher dies, the harness has no Stop to re-arm on, so supervision stays down: the beacon (`state/.last-watcher-beat`) goes stale far past `FM_GUARD_GRACE`, and incoming wakes such as new Telegram-routed tasks or crew status are never surfaced until a human notices.
This was observed live on 2026-08-15 with several homes' beacons stale for thousands of seconds while their panes stayed open.
The guardian is the layer that repairs that with no session in the loop.

## What it does per home

For each guarded home the guardian classifies supervision with the fleet's own model-aware predicates and acts only on a genuine lapse.

| Home state | Classification | Action |
| --- | --- | --- |
| No in-flight work, no relay poll, no event source | `idle` | none |
| Needs supervision, watcher beacon fresh for its model | `healthy` | none (never double-arms) |
| Needs supervision, beacon stale, director session alive | `lapsed` | never re-arm and never relaunch a live session; start a confirmation clock and escalate a likely wedge only after it stays lapsed past `FM_GUARDIAN_WEDGE_ESCALATE_SECS` |
| Needs supervision, beacon stale, local secondmate session dead | `dead` | relaunch the director through the sanctioned spawn path (rate-limited), else escalate |
| Needs supervision, beacon stale, main home has no session | `dead` | re-arm to capture wakes durably and escalate a human to start a session |
| Remote secondmate (another host) | `remote-skip` | none (a local timer cannot repair another host) |

Repair is honest about handling, not just about the beacon.
Re-arming a session-less home launches a real watcher, so the beacon is genuinely fresh and every wake is captured durably in `state/.wake-queue`; the guardian never fakes a beacon.
It deliberately does not re-arm a home whose session is still alive: a guardian-owned watcher would freshen that beacon and mask a wedged session, and re-arm gives an asleep session no handler anyway.
Because a surfaced wake is handled by the home's own live session, the guardian relaunches a dead local director to restore a handler and escalates a home it cannot safely restore rather than masking it behind a fresh beacon.
Wakes are not lost while a live session is only escalated: their signal and status files persist, and a watcher scans them once the session resumes or is relaunched.

## Safety properties

- It re-arms only through a self-surviving `systemd-run --user` transient unit, never a fire-and-forget shell `&`, which the `bin/fm-watch-arm.sh` header documents as the exact mistake that silently killed supervision for about thirty minutes.
- It never double-arms: a healthy home is left completely alone, and the watcher singleton lock plus `fm-watch-arm.sh`'s own attach make any concurrent arm converge on one watcher.
- It never kills live crew, discards unlanded work, or force-tears-down; the only relaunch path is the sanctioned `fm-spawn.sh --secondmate`, which reconciles rather than discards.
- It never stops, restarts, or touches the shared no-mistakes daemon.
- Relaunches and escalations are rate-limited per home, so a crash-looping home is escalated instead of hammered.
- It exports `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` before any `systemctl --user` call and uses absolute paths, so it runs correctly from the bare environment a timer provides.

## Boundary and the unattended-handling decision

The guardian keeps supervision armed and relaunches dead directors, but it does not make wakes self-handle with zero session.
The only design that self-handles routine wakes without any session is the away-mode sub-supervisor daemon ([`AGENTS.md`](../AGENTS.md) section 8), which is a fleet-behavior change: it batches escalations, changes the token tradeoff, and injects into panes.
The guardian deliberately leaves that choice to the captain rather than imposing it.
If a director is genuinely wedged rather than merely unsupervised, the guardian escalates it instead of masking it, so the captain can decide whether to adopt unattended daemon mode fleet-wide as a follow-up.

## Install

The guardian is inert until installed as a systemd user timer.
Templates live in `dist/systemd/`.
Firstmate installs and enables it on the live box; do not enable it from a task worktree.

```sh
mkdir -p ~/.config/systemd/user
cp <repo>/dist/systemd/fm-liveness-guardian.service ~/.config/systemd/user/
cp <repo>/dist/systemd/fm-liveness-guardian.timer   ~/.config/systemd/user/
# Edit FM_GUARDIAN_MAIN_HOME in the .service if the main home is not ~/firstmate.
loginctl enable-linger "$USER"   # so user units run with no active login session
systemctl --user daemon-reload
systemctl --user enable --now fm-liveness-guardian.timer
```

`loginctl enable-linger` is required: without it user units do not run while no one is logged in, which is exactly when the guardian matters.

Escalations go to the guardian log by default.
To also raise an active captain-facing signal (a Telegram ping, a checkpoint), set `FM_GUARDIAN_ESCALATE_CMD` in the `.service` to a command invoked as `<cmd> <home> <summary>`; see the script header for the seam contract.

## Verify it live

```sh
systemctl --user list-timers fm-liveness-guardian.timer    # next/last fire
systemctl --user status fm-liveness-guardian.service       # last pass result
<repo>/bin/fm-liveness-guardian.sh --list                  # classify every home, repair nothing
tail -f ~/.local/state/fm-liveness-guardian.log            # actions and escalations; silent when healthy
```

A quiet log is a healthy fleet: the guardian writes a line only when it re-arms, relaunches, escalates, or errors.
To confirm the repair path end to end, watch `list-timers` fire while a home's beacon is genuinely stale, then confirm that home's beacon becomes fresh and a `systemd-run` transient unit (`systemctl --user list-units 'fm-fleet-*'`) is briefly present.
