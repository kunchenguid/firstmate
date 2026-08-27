# Usage-limit survivability verification

Active empirical evidence for the guarantees in [`docs/usage-limit-survivability.md`](../usage-limit-survivability.md).
Refresh it by re-running the commands below on the host in question.

## Environment

- Dates: 2026-08-26, extended 2026-08-27 with the live-fleet record and the predicted wall
- Platform: Darwin 25.5.0
- `quota-axi 0.1.17` (below the `FM_QUOTA_AXI_MIN` floor, which is the case the reading is required to survive)
- `no-mistakes version v1.57.0 (0fcbbff) 2026-08-22T05:14:30Z`
- `tmux 3.7b`

## The gauge reads, and an unread gauge is distinguishable from a healthy one

`bin/fm-usage-wall.sh headroom` against the live `quota-axi`, one measurable provider and five unmeasurable ones in a single reading:

```
HEADROOM: claude tight pct=10 bound=five_hour resets=2026-08-27T02:20:00.207154+00:00 runway=5m confidence=established
HEADROOM: codex unknown reason=provider-read-failed status=error auth=unknown
HEADROOM: cursor unknown reason=auth-required status=auth_required auth=unknown - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: copilot unknown reason=auth-required status=auth_required auth=unknown - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: grok unknown reason=auth-required status=auth_required auth=unusable - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: kimi unknown reason=auth-required status=auth_required auth=unknown - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM_SUMMARY: verdict=tight measured=1 tight=1 wall=0 unknown=5 source=quota-axi/0.1.17 build=below-floor(0.1.29)
HEADROOM_NOTE: an unknown provider is UNMEASURED, not healthy - treat its headroom as unproven when deciding what to dispatch.
HEADROOM_NEXT: <repo>/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.
```

The same command with no `quota-axi` on `PATH`.
The verdict is `unknown` with its reason, never `ok`:

```
HEADROOM: (all providers) unknown reason=quota-axi is not installed
HEADROOM_SUMMARY: verdict=unknown measured=0 tight=0 wall=0 unknown=1 source=quota-axi/unavailable
HEADROOM_NOTE: headroom is UNMEASURED, not healthy - install it with npm install -g quota-axi to get a reading.
HEADROOM_NEXT: <repo>/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.
```

`tests/fm-usage-wall.test.sh` pins the remaining unmeasurable paths - a failing gauge, a hanging gauge, a report with no derived-headroom block, and `auth_required` - along with the rule that `--allow-keychain-prompt` is never passed.

`tight` is reached by either threshold independently, which a single reading can show.
On 2026-08-27 the same command reported the measurable provider at 84 percent remaining and still called it `tight`, because the projected runway was inside the hour:

```
HEADROOM: claude tight pct=84 bound=five_hour resets=2026-08-27T08:39:59.783103+00:00 runway=35m confidence=early
HEADROOM_SUMMARY: verdict=tight measured=1 tight=1 wall=0 unknown=5 source=quota-axi/0.1.17 build=below-floor(0.1.29)
```

## The gauge saw a real wall before it landed

This is the guarantee working against a wall that actually arrived, rather than a constructed one.

While this surface was being built on 2026-08-26, the gauge read the account's five-hour window at 9 percent remaining with roughly four minutes of projected runway.
The worker recorded that reading, and the wall landed minutes later and stopped the account's workers, exactly as the reading projected.
The work on every branch survived it, and the record below is what a session picks the fleet back up from.

That is the whole point of reading the gauge before dispatching rather than after a crash log: the wall was visible while there was still time to act on it.

## The record generates from real fleet state

`bin/fm-usage-wall.sh resume --out <path>` run against a home with six tasks in flight, then read back from disk after the process that wrote it exited.
`--out` writes only to the named path, so a read-only inspection never disturbs the home's own record.

Task identifiers, local-copy paths, and pull-request URLs are redacted here because they are private fleet state; the structure and the verdicts are verbatim.
Both load-bearing warnings fired on real data, unprompted:

```
# Resume record

generated: 2026-08-27T03:46:06Z
home: <home>
source: bin/fm-usage-wall.sh resume
tasks in flight: 6

This record is GENERATED from live durable state. Do not hand-edit it; regenerate it.
It carries state only. The recovery procedure is owned by the usage-limit-recovery skill.
Nothing here is a merge authorisation: each task keeps the posture recorded on its own line.

## <task-a>

- kind: ship
- merge posture: mode=no-mistakes yolo=off (the captain approves every merge)
- runtime: harness=claude model=claude-opus-5 effort=xhigh backend=tmux
- endpoint: <endpoint-a> (present)
- local copy: <copy-1>
  - SHARED: another task in this home records the same local copy; resolve which one owns it before resuming either
- branch: <branch-a> head: feb6865 uncommitted: 2 unpushed commits: (branch not on origin)
- pipeline: no run is attributed to this local copy
- pull request: -
- current state: state: working · source: pane · harness busy (claude-hook)
- open captain calls: (none)
- delivered instructions: 0 acknowledged, 0 still unread by the worker

## <task-d>

- kind: ship
- merge posture: mode=no-mistakes yolo=off (the captain approves every merge)
- runtime: harness=claude model=claude-opus-5 effort=high backend=tmux
- endpoint: <endpoint-d> (present)
- local copy: <copy-4>
- branch: <branch-d> head: 2bf7e9ca uncommitted: 0 unpushed commits: 7
- pipeline: run=01M10N2BCHBB680G3H0H7YQDSM status=running failed-steps=- custody=pipeline_owned next-action=continue_active_run head=4b2a52db (pipeline-only)
  - the pipeline owns this branch; settle custody through its next-action before any new work on it
  - the run holds commits this local copy does not have; rebuilding from the local head would silently redo work that already exists
- pull request: -
- current state: state: failed · source: run-step · run failed
- open captain calls: (none)
- delivered instructions: 0 acknowledged, 0 still unread by the worker
```

`<task-a>` and a second task record the same local copy, and the record flags the collision on both rows rather than silently picking one.
`<task-d>` is the stranded shape the whole surface exists for: the run is `pipeline_owned`, its head is `pipeline-only` - not present in the local copy at all - and the record says in words that starting from the local head would rebuild work that already exists.
Neither line is inferred from an incident write-up; both are computed from task metadata, the local copies, and the pipeline overview at the moment the command ran.

The remaining four tasks are elided for length.
`tests/fm-usage-wall.test.sh` pins the same behaviors portably, including that the record survives the process that wrote it, that regeneration replaces rather than accumulates, that a shared local copy is named on both rows, and that a broken record never replaces a good one.

## The endpoint-gone recovery, end to end

Run on a disposable scratch task on a private tmux socket, never on live work.
Steps 1 and 2 establish a task whose harness has just hit the wall; step 3 removes the whole terminal server, which is the shape of [issue #3113](https://github.com/kunchenguid/firstmate/issues/3113).

To reproduce: put a `tmux` shim on `PATH` that redirects to a private socket (`tmux -L <name>`, the pattern `tests/fm-backend-tmux-smoke.test.sh` uses); create a scratch `FM_HOME`, git repo, worktree, and `state/<id>.meta`; open the recorded session and window with the worktree as its working directory and print the vendor limit line into it; then run the steps below in order.
An unrelated turn-end guard banner is elided from step 6's output.

```

=== 1. the scratch task's endpoint exists and the harness has just hit the wall ===
fm-proofcrew
agent state: dead

=== 2. diagnose separates the wall from a crash ===
USAGE_WALL: proofcrew wall source=endpoint line="You've hit your weekly limit - resets Aug 26 at 10am (Europe/Rome)"
USAGE_WALL_NEXT: this is a provider usage limit, not a crash - the work is intact. Load the usage-limit-recovery skill before touching the task.

=== 3. the whole terminal server goes away (this is the #3113 shape) ===
agent state: missing

=== 4. control refuses while the endpoint is gone ===
error: task proofcrew's recorded endpoint is gone, so there is no agent to stop; reconcile the task before any further control action
exit status: 1

=== 5. the work itself is intact on the branch ===
fm/proofcrew
2f979c3 init

=== 6. teardown also refuses, because the work is unlanded ===
worktree <scratch>/wt is not managed by treehouse
error: treehouse return failed for worktree <scratch>/wt; teardown aborted
exit status: 1

=== 7. recreate the EXACT recorded endpoint, with the recorded local copy as its working directory ===
agent state: dead
window working directory: <scratch>/wt

=== 8. control now accepts the same command it refused in step 4 ===
already-stopped proofcrew harness=claude backend=tmux endpoint=fmproof:fm-proofcrew worktree=<scratch>/wt
exit status: 0

=== 9. relaunch gets past the endpoint gate too ===
error: task proofcrew has no instructions at <scratch>/home/data/proofcrew/brief.md; refusing to relaunch a worker with nothing to work from
exit status: 1
```

What this proves, in order: the wall is separable from a crash by evidence (step 2); an endpoint whose server is gone classifies as `missing` and both the control plane and teardown refuse, which is the deadlock (steps 3, 4 and 6); the work itself is untouched (step 5); recreating the exact recorded endpoint with the recorded local copy as its working directory makes the same endpoint classify as `dead` (step 7); and the control plane then accepts the command it refused four steps earlier (step 8), with `relaunch` passing the same gate and stopping only at a later requirement this synthetic task does not have (step 9).

The classification underneath it - a vanished server as `missing`, a plain shell as `dead` - is already pinned portably by `tests/fm-secondmate-liveness.test.sh`, so it is not duplicated here.
