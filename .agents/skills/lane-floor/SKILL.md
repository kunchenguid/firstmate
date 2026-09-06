---
name: lane-floor
description: >-
  Agent-only procedure for filling the fleet back to its lane floor.
  Use on any LANE FLOOR line, whether it comes from a wake drain or from a blocked turn end.
  Owns the order work is taken in, what a brief for an openspec Change must point at, and the memory bound that is the only legitimate reason to stop short of the floor.
user-invocable: false
metadata:
  internal: true
---

# lane-floor

A `LANE FLOOR` line means this home is running fewer lanes than `config/lane-floor` while work is dispatchable without a captain decision.
That is a defect, not a status: the captain is paying for idle capacity.
Fill the fleet in this turn, before ending it.

The line names the numbers and lists the work:

```
LANE FLOOR: live=4 floor=10 dispatchable=17 - load the lane-floor skill and dispatch before ending this turn
  backlog xau-run-ledger-ceiling
  openspec XAUUSD:dashboard-v21-redesign-part5-comparison-view:6
```

`backlog <id>` is an item already in this home's queue.
`openspec <project>:<change>:<n>` is a Change under a registered project clone whose `tasks.md` still carries `n` unticked boxes and that no live worker's instructions name.

## Procedure

Work the list until live lanes reach the floor, or until the memory bound below stops you.

1. **Take the list in the order it prints.** Backlog items come first because they are already filed, already scoped, and already carry their delivery mode.
2. **For a `backlog` line, dispatch it.** Resolve delivery mode and merge posture at intake exactly as any other dispatch, write the brief, and spawn.
   An item whose hold you cannot dispatch under is one the enumeration should not have listed; a `captain` hold is already excluded, so a remaining blocker means the item's own note is wrong.
   Fix the note by recording the exact blocking rule on the item, and move to the next line rather than dispatching blind.
3. **For an `openspec` line, file a task first.** The Change is work the fleet has not tracked, so it has no item yet.
   File one with a title naming the Change, `repo` set to that project, and a note pointing at the Change's own `tasks.md` path.
4. **Point the brief at the authority, not at a copy.** The brief's intent names the Change and its `tasks.md` path as the task's own scope, and says to complete its unticked boxes under that project's current authority.
   Never transcribe the boxes into the brief: `tasks.md` moves while the worker runs, and a copied list goes stale the moment another lane ticks a box.
5. **Spawn, then re-read the count.** After each spawn the live count rises by one; stop as soon as it reaches the floor.

Nothing here changes merge authority, delivery mode, or the captain-decision boundary.
A Change that turns out to need a captain call is filed and held `--kind captain` like any other, which removes it from the enumeration by its own record rather than by being skipped silently.

## The memory bound

A lane costs memory, and a host that swaps serves nobody.
Before each additional spawn, read the host's available memory and require at least 2 GB free per lane you are about to add:

```
free -g | awk '/^Mem:/ { print $7 }'
```

When that headroom is gone, stop spawning and report it to the captain in the same turn, naming the live count, the floor, and the measured headroom.
A memory shortage is a real constraint the captain needs to know about; it is never a reason to go quiet.
Say plainly that the fleet is short of its floor because the machine is out of memory, not that the fleet is fine.

## What does not clear a breach

- Ending the turn. The turn-end block and the drain escalation both return.
- Re-reading the list. Nothing is dispatched by looking at it.
- Deciding the work is low value. That is a captain call, filed as a held item, not an unrecorded skip.
- A lane that is paused. The count already excludes it, so replacing it is exactly the point.
