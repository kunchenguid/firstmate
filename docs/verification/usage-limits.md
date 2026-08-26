# Usage-limit survivability verification

Active empirical evidence for the guarantees in [`docs/usage-limit-survivability.md`](../usage-limit-survivability.md).
Refresh it by re-running the commands below on the host in question.

## Environment

- Date: 2026-08-26
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
