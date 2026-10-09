---
name: goodnight
description: >-
  Quiesce the fleet when the captain says /goodnight, "goodnight", or "going to bed", or state/.goodnight exists at session start or wake handling.
  Finish work already in hand, hold new dispatch and follow-up operations, and maintain the morning list; /goodmorning or /gm lifts the hold.
user-invocable: true
metadata:
  internal: true
---

# Goodnight

Goodnight is a scheduling hold for a machine the captain will shut down, not an OS shutdown command.
This skill owns the hold and its morning handoff.
Load `operational-home-layout` to resolve this home's effective state and data directories before writing them.
Keep the existing supervision session running while work is under way, including when away or quiet mode is also active.

## Entry and durable handoff

Enter in the same turn as the request, without waiting for another go.
Write `state/.goodnight` atomically with one UTC entry timestamp from `date -u '+%Y-%m-%dT%H:%M:%SZ'` followed by a newline.
Presence activates the hold: malformed or unreadable contents never mean permission to dispatch.
On a repeated entry, preserve the original timestamp and handoff rather than resetting the date or overwriting notes.
If an existing timestamp cannot be read, keep the hold and recover its entry date from the actual morning records; do not guess a date or discard a list.

Create `data/goodnight/<UTC entry date>.md` on entry, using the date from the record, even when the fleet is empty.
Inspect any existing list before updating it and preserve unresolved entries across repeated entry or a second goodnight on the same UTC date.
Give it these sections:

- Work in flight: each task's id, current checkpoint with its evidence pointer, and first action tomorrow.
- Deferred operations: each requested follow-up and the exact first action needed to resume it.
- Open decisions: each unresolved call with its key and authoritative record pointer.

Reconcile this home's recorded direct reports through `bin/fm-crew-state.sh` and each task's existing brief and validation records before claiming where it stopped.
Write facts already established by those records; mark an unknown checkpoint as unknown until checked.
Update the list as work settles, before cleaning up any finished task, preserving the outcome and next action after runtime records disappear.
Keep task notes in the backlog consistent with the list through the configured backlog backend.
The morning list supplements task and decision records; it never closes a keyed decision or changes a task's delivery mode.

Route goodnight to already-live registered secondmates through their parent channel so each writes its own home-local hold and list and reports its checkpoints back.
Each secondmate reconciles its own children; the parent records the returned summary and list pointer without inspecting the child's endpoint namespace.
Record an unavailable secondmate as a deferred delivery, preserving its existing home and work; never restart it merely to deliver the hold.

Tell the captain what this fleet still finishes and what waits, in plain language: implementation already in hand and reports finish, validation already running finishes its gates, and new validation handoffs and follow-up operations wait in the morning list.
State the list's actual path and any open decision that prevents current work from finishing.

## While the hold exists

- Spawn no new worker, scout, or secondmate; relaunching a recorded task to finish work already in hand remains allowed.
  `bin/fm-spawn.sh` enforces this boundary; its header and help own the refusal mechanics.
  `/gm` lifts the hold for the whole fleet, including secondmates and deferred items.
  There is no one-off exception.
  If the captain wants new work during the hold, lift it with `/gm`, accepting that deferred work may resume until `/gn` re-enters the hold.
- Let an implementation worker finish its current build and commit, then stop at its implementation `done` handoff.
  If its selected delivery path requires a validation pipeline that has not started, do not send `/no-mistakes` or hand it to a reviewer.
  Record `stopped before pipeline` in the task note and morning list, with starting its selected pipeline as its first action tomorrow.
  Preserve the worktree and unlanded work.
- A validation pipeline already active at entry continues through its existing gates to green.
  Answering those gates finishes current work: follow `validation-supervision` and `ask-user-authority`, including the ordinary escalation boundary.
  Land green work under the project's standing merge authority and the existing safety guards; when approval is still required, record that open call instead of assuming approval.
  No new pipeline or separate re-run starts during the hold.
- Scouts finish their report and follow `scout-completion`, including unresolved captain calls; do not promote them to implementation.
- Clean up finished, landed tasks through `ship-landing` and the guarded teardown path, retaining their outcomes in the list first.
  Never tear down unlanded work or discard a scout report before its completion gate passes.
- Defer follow-up rollouts, restarts, new briefs, separate re-runs, new investigations, and queued dispatch to the morning list instead of performing them.
  Capture newly requested work durably without starting it.

Goodnight controls scheduling in the attended session, Pi supervision branch, supervision host, and away/quiet daemon alike.
When an away or quiet record also exists, keep that mode's watcher ownership and return protocol; goodnight neither starts a second cycle nor clears those records.
The spawn refusal is the shared enforcement point, not a separate daemon policy implementation.
Goodnight does not kill or interrupt workers, change merge authority, suspend, or shut down the machine.

## Morning

At session start with the marker present, read the digest's morning-list path and that list, present where work stopped and the first actions, and ask whether to lift the hold.
Starting a session, ordinary chat, returning from `/afk`, and leaving `/quiet` do not lift it.
Honor a lock-refused session's read-only boundary: it cannot enter, lift, or update the hold.

An explicit `/goodmorning`, `/gm`, or a plain request to lift goodnight authorizes lifting it immediately.
Read the active morning list before removing `state/.goodnight`, retain the list, and report that new dispatch can resume.
Route the explicit lift to the secondmates that entered goodnight and reconcile their replies through the parent channel, retaining any undelivered lift in the list.
If the list is missing or unreadable, disclose that gap and reconstruct checkpoints from task records before acting on deferred work; explicit lifting still permits removing the marker.
Then reconcile each deferred item against current task and decision records before resuming it, so an already-finished operation is not repeated.
If no marker exists, report that goodnight is already off and resume only work already authorized.
