---
name: sos-dispatch-loop
description: >-
  Load on any `procevent when sos-* <sequence>` wake, before running bin/fm-issue-intake.sh,
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
`bin/fm-issue-intake.sh` turns that event - or an open `sos`-labeled GitHub
issue, which heals lost events - into durable work keyed on the SOS message
UUID: one task row (a bead on a beads backend), one lifecycle comment thread
on the issue, one close watch, and - for a ticket the worth-supporting gate
supports - one dispatched crewmate.

## Operating contract

- Run `bin/fm-issue-intake.sh reconcile` on an SOS wake, and periodically when
  tickets are outstanding.
  It is idempotent end to end: the task row id is the idempotency record (the
  script header owns its exact format, including pre-rename `fm-sos-` rows), so
  replays and lost cursors can never double-dispatch.
- Every candidate passes the worth-supporting verdict gate (`jev verdict`)
  first: `supported_bug` dispatches automatically - no manual triage step -
  and never onto an issue that is already closed: no comment, no watch, and no
  spawn against a closed ticket - `not_supported` is declined and closed by
  intake, except for a ticket already dispatched to a crewmate, which is
  reported for the captain instead and never declined or closed - work in
  flight is never yanked - a ticket the captain already closed, which is left
  untouched (no decline comment, no close) - a ticket with an earlier
  recorded close that GitHub no longer confirms, held for the captain instead,
  never dispatched and never declined - and `captain_review` is held for the
  captain with no spawn.
  `--no-verdict` skips new classification for an ops run; ledgered verdict and
  decline decisions still bind. `--mode`/`--yolo` (or `FM_ISSUE_MODE`/`FM_ISSUE_YOLO`) set the
  spawned task's delivery contract; they are posture, not selection.
- Transition comments only through `bin/fm-issue-intake.sh comment <issue>
  <transition> "<one line>"` (dispatched, declined, repro-confirmed, fix-up,
  deployed, verified, captain-closed).
- THE LOOP CLOSES A GITHUB ISSUE ONLY FOR A `not_supported` DECLINE, at intake.
  The captain closes every other issue after verification; the close watch
  fires only because the captain already closed it.
- The GitHub issue body is the working report and may contain clinical
  speech: keep it out of commits, logs, and task rows.

## Close-watch wakes

`procevent when sos-<issue> <sequence>` outcomes classify through
`bin/fm-procevent-when.sh classify`:

- `fired`: the watch saw the captain's close; the action already posted the
  captain-closed comment and closed the task row.
  Acknowledge with `bin/fm-procevent.sh handled`. The next reconcile retires
  the fired spec; if the issue is open again it is reported as review work.
- `never-true`: the deadline passed with the issue still open.
  Surface the ticket to the captain as review work; do not re-arm blindly.
- `action-failed` or `condition-error`: the fire or its effect is uncertain.
  Verify manually, acknowledge the wake with `bin/fm-procevent.sh handled`,
  and retire the dead spec with `bin/fm-procevent-when.sh retire sos-<issue>`
  (an unacknowledged captured round blocks the retire); only then does
  `bin/fm-issue-intake.sh reconcile` re-arm the watch, while the issue is
  still open (a watch that already fired is never re-armed for a closed
  issue's work).
- A late replay after a successful fire may arm one redundant watch; the
  ledger's `closed` line makes its fire a no-op.

After a firstmate self-update changes `bin/`, run
`bin/fm-procevent-when.sh rebind-all`: the watch hash-binds the intake
script's bytes and a stale binding refuses the fire.
