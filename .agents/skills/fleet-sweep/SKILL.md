---
name: fleet-sweep
description: Run a supplemental whole-fleet reconciliation only when the captain explicitly invokes /fleet-sweep, without replacing ordinary status, supervision, or scheduling owners.
user-invocable: true
metadata:
  internal: true
---

# fleet-sweep

Run this skill only for the captain's exact `/fleet-sweep` invocation.
Route ordinary status, catch-up, and supervision requests through their existing owners instead.
This sweep is a supplemental bounded reconciliation and never replaces, duplicates, schedules, or creates another owner for the watcher, wake drain, Bearings, AFK, secondmate supervision, pending replies, or capacity controls.

## Establish the sweep baseline

1. Run `bin/fm-wake-drain.sh` first, handle every presented record and open decision under the emitted supervision contract, and acknowledge only after handling.
2. Read the latest durable `data/captain-shared.md` when present and preserve its routing rules throughout this sweep.
3. Run `bin/fm-fleet-snapshot.sh --json` and treat its structured output as the initial fleet inventory.
4. Treat every status-file line as an append-only wake event and use `bin/fm-crew-state.sh <id>` whenever an action depends on a worker's current state.
5. Inventory every registered secondmate, child, pending reply, remote-reply route, open decision key, merge-ready or migration-ready item, blocked child, inactive or stale worker, and omitted or unavailable snapshot surface.

## Reconcile every home

1. Send every registered secondmate one marked request through `bin/fm-send.sh` to reconcile every recorded child against live current state and return one correlated aggregate report through the existing parent reply route.
2. Require each report to classify all recorded children, disclose omitted children, cover current-cycle Linear work, and name the evidence for blockers, capacity constraints, stale workers, ready work, and parent-bound updates.
3. Keep the ordinary supervision cycle active while replies are outstanding, and drain wakes as they arrive so parent-home appends and pending-reply resolutions are durably ingested.
4. Follow the pending-reply and remote-reply owners for their bounded recovery and failure handling rather than inventing a retry loop or timeout.
5. If a secondmate aggregate report is unavailable, invalid, partial, or timed out, rerun `bin/fm-fleet-snapshot.sh --json` and use that lane's supported bounded direct-home record under `secondmate_current`.
6. If the bounded direct-home record is also unavailable, invalid, partial, truncated where required, or missing the lane, classify the lane as unavailable and never infer that it is clear.
7. Finish only after every requested reply is durably ingested or its named transport failure is surfaced, while ordinary supervision remains active throughout the wait.

## Reconcile work and Linear

Load and follow the available `orca-linear` skill before any Linear read or write, including its version-matched runtime guide.
Sweep every current-cycle Linear item visible across the main home and secondmate reports, and classify each as progressing, genuinely blocked by a named unresolved dependency, or capacity constrained by concrete slot or host-resource evidence.
Treat a vague, stale, already-cleared, wrong-layer, or standing-policy-cleared blocker as fictitious, then repair it or route it through the existing task owner.
Correct Linear status only when current live evidence proves the recorded status stale.
Respect the latest durable captain-shared routing, so a worker that already progressed finishes its current bounded slice while parking applies to unstarted, replacement, and follow-on work.
Treat capacity as constrained only when concrete slot or host-resource evidence proves it, and otherwise move already-authorized ready work through existing capacity controls without creating another scheduler.

Within current standing authority, the sweep may nudge or safely recover existing workers, clear fictitious blockers, dispatch ready work already authorized by current captain priorities, and correct stale Linear status.
Load every existing owner skill required by an action, including recovery, dispatch, decision, process-event, and Linear owners, and follow its mechanics rather than restating them here.
Do not invent work, open a lane contrary to current priorities, change product scope or priority, merge without captain authority, perform a destructive or irreversible action, or broaden external side effects.

## Report to the captain

Give one concise, complete result that includes every category below, using an explicit empty state when a category has no items.

- List actions only the captain can take.
- List autonomous repairs, dispatches, and Linear corrections completed during the sweep.
- List work confirmed progressing.
- List real blockers with their owners and named unresolved dependencies.
- List capacity constraints with their concrete slot or host-resource evidence.
- List unavailable lanes with the failed report or transport route.
- List every item the sweep could not reconcile and why.

Never hide an omission inside a healthy aggregate, and never report an unavailable or unreconciled lane as clear.
