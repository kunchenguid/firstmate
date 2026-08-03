# Task usage

Firstmate records codeburn usage automatically for each crewmate and scout cycle.
`bin/fm-spawn.sh` records `spawned_at=` and saves the worktree's pre-launch codeburn totals in `data/<id>/usage-baseline.json`.
`bin/fm-task-usage.sh <id>` queries the same worktree and UTC date window, then subtracts that baseline to exclude previous occupants of a pooled worktree slot.
`bin/fm-teardown.sh` saves the final delta as `data/<id>/usage.json` before deleting volatile task metadata.
The durable snapshot keeps completed-task usage in `fm-fleet-snapshot.v1` after worktree return and pool reuse.

The JSON contract is owned by `bin/fm-task-usage.sh` and identified by `fm-task-usage.v1`.
It reports the dispatched harness and configured model from task metadata, actual model names and totals from codeburn, tokens, cost, and call count.
Old metadata without `spawned_at=` or a baseline degrades to a worktree-and-date-scoped total instead of failing.
That fallback can include an earlier same-day occupant, while all newly spawned tasks use baseline subtraction.

Usage collection is best effort.
A missing or unreadable codeburn result never blocks spawn or teardown, and the fleet snapshot marks live usage unavailable.
Each codeburn call is bounded by a timeout (`FM_TASK_USAGE_TIMEOUT`, default 15s) so a hung report never stalls spawn, teardown, or fleet-snapshot generation.
`bin/fm-fleet-snapshot.sh` queries every live task's usage in parallel, each bounded by the shorter `FM_FLEET_USAGE_TIMEOUT` (default 5s), so total wait stays bounded by the slowest single call instead of the sum across the whole fleet.
The snapshot read never writes persistent data.
When `state/usage-cache/<id>.json` already exists, a timed-out or failed live query may serve that reading with `stale:true` instead of blanking to unavailable.
`bin/fm-teardown.sh` deletes that task's `state/usage-cache/<id>.json` entry alongside its other volatile state, so a torn-down task never leaves an orphaned live-usage cache behind; the durable `data/<id>/usage.json` snapshot is unaffected.
