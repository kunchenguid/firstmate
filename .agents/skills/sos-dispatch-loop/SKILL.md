---
name: sos-dispatch-loop
description: >-
  Load on any `procevent when when-sos-* <sequence>` wake, before running bin/fm-sos-intake.sh,
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
  It is idempotent end to end: the task row id is `fm-sos-<SOS UUID>`, so replays
  and lost cursors can never double-dispatch.
- Auto-dispatch is an explicit captain grant, never a default: it runs only while `config/sos-autodispatch` exists in the firstmate home.
  Without the grant, reconcile still ensures the task row and close watch but posts no dispatched comment and spawns no crewmate, printing a `dispatch-held ... reason=autodispatch-not-granted` line and leaving the cursor unadvanced (the pass still exits 0) so the held ticket dispatches once the grant exists; `status` shows whether the grant is present.
  Never create the grant yourself - only the captain does.
- With the grant, every SOS is dispatched: no confidence gate, no triage.
  The spawn consults the dispatch profile first, exactly as AGENTS.md section 4 requires at every crewmate or scout intake: reconcile resolves the concrete profile `fm-spawn` needs and passes it alongside `--mode`/`--yolo`, so a home with an active `config/crew-dispatch.json` dispatches through its rules instead of being refused.
  `--mode`/`--yolo` (or `FM_SOS_MODE`/`FM_SOS_YOLO`) set the spawned task's delivery contract; they are posture, not selection.
- A ticket whose dispatch profile cannot be resolved stays owed, never skipped: reconcile fails that pass with a named, greppable dispatch-blocked line, records it durably in the ledger, surfaces it through `bin/fm-sos-intake.sh status`, and leaves the cursor unadvanced so the next pass retries the ticket.
  `status` reports the current state: a block is listed only while its ticket is still open and owed - reconcile supersedes it with a `dispatch-skipped` line once the ticket can never dispatch again - while the ledger keeps the full append-only history, so repair and re-run applies only to a block `status` still shows.
  Repair the dispatch profile resolution (the `config/crew-dispatch.json` rules or the resolver) and re-run reconcile; never clear the block by spawning the task yourself with an invented harness.
- Transition comments only through `bin/fm-sos-intake.sh comment <issue>
  <transition> "<one line>"` (dispatched, repro-confirmed, fix-up, deployed,
  verified, captain-closed).
- THE LOOP NEVER CLOSES A GITHUB ISSUE.
  The captain closes it after verification; the close watch fires only
  because the captain already closed it.
- The GitHub issue body is the working report and may contain clinical
  speech: keep it out of commits, logs, and task rows.

## Close-watch wakes

`procevent when when-sos-<issue> <sequence>` outcomes classify through
`bin/fm-procevent-when.sh classify`:

- `fired`: the captain closed the issue; the action already posted the
  captain-closed comment and closed the task row.
  Acknowledge with `bin/fm-procevent.sh handled`.
- `never-true`: the deadline passed with the issue still open.
  Surface the ticket to the captain as review work; do not re-arm blindly.
- `action-failed` or `condition-error`: the fire or its effect is uncertain.
  Verify manually. For an issue the captain already closed, re-run the
  idempotent action - `bin/fm-sos-intake.sh watch-fire <issue> <sos-key>`,
  the key is any `key=... issue=<n>` line in the intake ledger (or the armed
  watch's `when/when-sos-<n>.spec` action argv) - which posts the
  captain-closed comment once, records the `closed` handoff only after the
  row close succeeded, and exits non-zero while the close is still owed.
  For an issue still open, run `bin/fm-sos-intake.sh reconcile`, which
  re-arms the watch while the issue is still open (a watch that already fired
  is never re-armed for a closed issue's work).
- A late replay after a successful fire arms no new watch - the captured
  verdict ends that issue's watch; the ledger's `closed` line makes its
  fire a no-op.

After a firstmate self-update changes `bin/`, run
`bin/fm-procevent-when.sh rebind-all`: the watch hash-binds the intake
script's bytes and a stale binding refuses the fire.
