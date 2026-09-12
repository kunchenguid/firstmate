---
name: fleet-cleanup
description: >-
  Agent-only procedure for clearing finished fleet work without losing anything.
  Load before a cleanup pass over several finished tasks, when the captain asks to clean up or clear the fleet, and before tearing down a task whose record you have not classified.
  Owns record classification, the refusal-is-a-stop rule, backlog id spaces, interrupted-close replay, hung-read handling, landing fan-out, and quota-blocked relaunch.
user-invocable: false
metadata:
  internal: true
---

# fleet-cleanup

Load this before a cleanup pass over finished fleet work, and whenever the captain asks to clean up the fleet.
Cleanup is the one routine that destroys things, so every step below either proves a fact or refuses.
Nothing here replaces a script's own contract: each section points at the owner rather than restating it.

## Classify every record before touching it

`state/<id>.meta` records `kind=`, and the three kinds take three different actions.
A `kind=secondmate` record is a persistent agent, never a backlog item and never an ordinary teardown: load `secondmate-provisioning` and retire it only on an explicit decision.
A `kind=scout` record's worktree is declared scratch and its report at `data/<id>/report.md` is the deliverable, so read and relay the report before anything is discarded.
A `kind=ship` record's worktree can still hold the only copy of the change, so it is the one that must prove landing.
Classify from the record, not from the task name or from how finished the work sounds, and read live state with `bin/fm-crew-state.sh <id>` rather than the tail of a status log, which is an event history.

## Never discard unlanded work

This is the rule the whole procedure exists to protect.
`bin/fm-teardown.sh` hard-resets and removes the worktree and kills its processes, so anything it removes that had not landed is gone.
Uncommitted changes are never landed, and `--force` is only for a case where the captain has explicitly said to discard that specific work.
Treat a teardown refusal as a stop-and-investigate result, never as an obstacle to route around.

## Tear down only after landing is confirmed

Confirmed, not assumed: the header of `bin/fm-teardown.sh` owns the complete landed-work test and every fallback in it.
The property that matters during a cleanup pass is that teardown refuses when the evidence is inconclusive rather than guessing, so "the worker said done" and "the PR looks merged" are not inputs to this decision.
A scout carves out of the landed-work test but not out of a gate: it proceeds only once the report exists and the shared unresolved-decision completion gate passes, which is why `captain-hold-lifecycle` loads before an investigation is treated as complete.

## Backlog ids: minted and legacy

Two id spaces are in play, and only one of them can be re-filed.
Beads mints short ids under a configured `issue_prefix`, which is `fm` on this fleet, so its ids read `fm-0hw`; older records instead carry descriptive slugs such as `crew-state-live-run-precedence`.
Do not read that prefix as a beads universal, because another home's `bd config` can set a different one.
A descriptive slug has no beads issue behind it: `bd show crew-state-live-run-precedence` answers `no issue found matching`, while `bd show fm-0hw` returns the issue.
When you meet a legacy descriptive id, close it in the backend that actually holds its row and let `bin/fm-teardown.sh` perform that transition under the task's own lock.
Never mint a replacement id to re-file a legacy record: the meta, status log, worktree, and any pending close all key on the recorded id, so renaming it strands every one of them.
`bin/fm-backlog-transition-lib.sh` owns how a transition is addressed to the owning home's configured backend.

## Finish an interrupted close

A cleanup killed between removing the record and landing its backlog transition leaves `state/<id>.backlog-close` behind, and that file is the only remaining copy of the intended transition.
The next locked session start in the owning home replays it, reporting either a `BOOTSTRAP_INFO:` line naming what it closed or retained, or a `BACKLOG_RECONCILE: <id>: recorded backlog close could not be replayed` line.
Finish it by running that home's session start, not by hand-closing the row and not by deleting the marker, and load `bootstrap-diagnostics` on the `BACKLOG_RECONCILE` line.
A `BOOTSTRAP_INFO:` variant saying an endpoint or local copy may remain means the replay landed but cleanup did not finish, so reconcile that record before considering the task gone.

## A hung read is not a missing record

Observed 2026-09-03 on this fleet, not a diagnosed defect: `tasks-axi show <id> --backend beads` returned nothing within a 25 second bound while `bd show <id>` answered the same id in about a quarter of a second.
The safe response is to bound every backlog read with `timeout` and to confirm through the fast path before drawing any conclusion.
A read that hung is evidence about the read, never evidence that the record is missing, already closed, or safe to tear down.

## Fan out the landing crews

Landing work in different projects is isolated by construction, because each project is a separate repository and each task gets its own worktree.
So dispatch one landing crew per project at once under `AGENTS.md` section 7, which sets no concurrency cap and treats overlap as a risk signal rather than a reason to wait.
Serialize only for a genuine semantic dependency or shared mutable external state; a backlog of finished work is not one.

## Relaunch a quota-blocked seat

A seat idle because its runtime is out of allowance is blocked, not wedged, so the escalation ladder in `stuck-crewmate-recovery` does not apply and its work needs no recovery.
Replace it with `bin/fm-control.sh <id> relaunch --harness <name> --note '<progress so far>'`, which swaps the agent inside the same endpoint and worktree; switching harness is an ordinary use of that verb.
That script's header owns what a failed replacement leaves behind, and the distinction matters here: a failure before the new record is published keeps the prior record, but once it is published the new record is deliberately kept, so the task reads as running on the new harness with no agent alive.
Reconcile that residue rather than assuming a clean rollback.
Choose the replacement candidate through the ordinary dispatch route on current quota evidence, loading `quota-array-dispatch` when a configured profile offers more than one, rather than picking a runtime by name.
Leaving the seat stalled is the failure mode this exists to prevent: the work is preserved either way, so the only cost of relaunching onto a healthy candidate is the note you carry across.
