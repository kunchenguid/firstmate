---
name: sos-dispatch-loop
description: >-
  Load on any `procevent when sos-* <sequence>` wake, before running bin/fm-sos-intake.sh,
  and when an ops-hq SOS ticket or a stack-monitor sos event needs dispatch.
  Owns the operating contract for the SOS dispatch loop: intake, auto-dispatch,
  lifecycle comments, and the captain-close watch.
user-invocable: false
metadata:
  internal: true
---

# sos-dispatch-loop

Portal files every staff SOS as a GitHub issue and fires one PHI-free event at
stack-monitor's typed event bridge (`docs/ops/sos-dispatch-loop.md` in
ArcsHealth/Portal owns the whole loop and its rationale).
`bin/fm-sos-intake.sh` turns that event - or an open `sos`-labeled GitHub
issue, which heals lost events - into durable work keyed on the SOS message
UUID: one task row (a bead on a beads backend), one dispatched crewmate, one
lifecycle comment thread on the issue, and one close watch.

## Operating contract

- Run `bin/fm-sos-intake.sh reconcile` on an SOS wake, and periodically when
  tickets are outstanding.
  It is idempotent end to end: the task row id is `sos-<SOS UUID>`, so replays
  and lost cursors can never double-dispatch.
- Auto-dispatch is every SOS: no confidence gate, no triage, no hold.
  `--mode`/`--yolo` (or `FM_SOS_MODE`/`FM_SOS_YOLO`) set the spawned task's
  delivery contract; they are posture, not selection.
- Transition comments only through `bin/fm-sos-intake.sh comment <issue>
  <transition> "<one line>"` (dispatched, repro-confirmed, fix-up, deployed,
  verified, captain-closed).
- THE LOOP NEVER CLOSES A GITHUB ISSUE.
  The captain closes it after verification; the close watch fires only
  because the captain already closed it.
- The GitHub issue body is the working report and may contain clinical
  speech: keep it out of commits, logs, and task rows.

## Close-watch wakes

`procevent when sos-<issue> <sequence>` outcomes classify through
`bin/fm-procevent-when.sh classify`:

- `fired`: the captain closed the issue; the action already posted the
  captain-closed comment and closed the task row.
  Acknowledge with `bin/fm-procevent.sh handled`.
- `never-true`: the deadline passed with the issue still open.
  Surface the ticket to the captain as review work; do not re-arm blindly.
- `action-failed` or `condition-error`: the fire or its effect is uncertain.
  Verify manually, then run `bin/fm-sos-intake.sh reconcile`, which re-arms
  the watch while the issue is still open (a watch that already fired is
  never re-armed for a closed issue's work).
- A late replay after a successful fire may arm one redundant watch; the
  ledger's `closed` line makes its fire a no-op.

After a firstmate self-update changes `bin/`, run
`bin/fm-procevent-when.sh rebind-all`: the watch hash-binds the intake
script's bytes and a stale binding refuses the fire.
