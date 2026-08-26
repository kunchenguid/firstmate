# Usage-limit survivability

A provider usage limit is not a crash.
It looks like one, and that is the entire problem this surface exists to solve.

When an account hits its limit, every worker on that account dies inside the same minute.
The harness exits non-zero, the validation run goes terminal with findings still awaiting, nothing is pushed, and no pull request appears.
On 2026-08-23 that shape cost roughly an hour of manual reconstruction across five workers, and the reconstruction was entirely re-derived: the cause was legible only in the pipeline step logs, which both ended on the vendor's own limit line followed by the harness's non-zero exit, while the run status said nothing but `failed`.

The same wall was survived cheaply three days later, and the difference was not skill.
It was one gauge reading taken before the wall and one written plan.
Both of those depended on a hand-written file and on a single session remembering a procedure, and neither survives a context reset or reaches a home that has never hit the wall.

This surface makes both structural.

## Shape

One command owns the data, one skill owns the procedure, and neither restates the other.

| Piece | Owns |
| --- | --- |
| [`bin/fm-usage-wall.sh`](../bin/fm-usage-wall.sh) | `headroom`, `diagnose`, and `resume`: the gauge, the verdict, and the record |
| `.agents/skills/usage-limit-recovery` | The recovery procedure, and the four facts that make it cheap |
| [`bin/fm-session-start.sh`](../bin/fm-session-start.sh) | Printing the gauge and the wall scan where they cannot be missed |
| [`bin/fm-fleet-view.sh`](../bin/fm-fleet-view.sh) | Printing the gauge at every heartbeat review |

The command's own header is the authoritative description of its behavior, flags, exit statuses, and tunables.
This document covers why the pieces are shaped the way they are.

## Why unmeasurable is a first-class verdict

`quota-axi` returns `auth_required` and unknown headroom until the operator approves local credential access once, and that approval blocks on a system dialog.
A gauge that rendered "could not read it" the same way as "plenty left" would be worse than no gauge, because it would be trusted.

So `headroom` has three provider verdicts that mean a reading was taken (`ok`, `tight`, `wall`) and one that means none was (`unknown`), and there is no code path from a failed read to a healthy verdict.
Absent, erroring, hanging, unparseable, unresolved, and unauthenticated all land on `unknown` with the concrete reason attached, and the one-time operator command is named on the line that needs it.
The command never passes `--allow-keychain-prompt` itself: it runs inside a session-open hook that blocks the first turn, and a blocking dialog there would cost the whole session.
`tests/fm-usage-wall.test.sh` pins each of those paths separately, including that the flag is never passed.

`tight` is presentation, not policy.
It labels a reading; it never gates, blocks, or reorders a dispatch.
Firstmate and the captain decide what runs, and there is deliberately no budgeting, scheduling, or admission logic anywhere in this surface.

Headroom is read out of `quota-axi`'s default TOON rather than its JSON, because at the observed build (0.1.17) `quota-axi --json` is schemaVersion 3 and carries raw provider windows only, with no derived headroom, status, or authentication fields at all.
The TOON block is parsed by field name out of its own declared header, so an upstream provider, window, or field addition shifts nothing; a reordered report is a test case, not a hope.
A `quota-axi` older than the floor `bin/fm-quota-axi-lib.sh` owns still yields a reading, labelled `build=below-floor`, because blanking a working gauge to `unknown` would be a false negative in exactly the case it exists for.
`bin/fm-bootstrap.sh` remains the owner of the operator-facing MISSING diagnostic for that build.

## Why the record is generated, not saved

The instinct after an incident like this is to write the plan down before the wall.
That is the wrong lesson, and it is the one that nearly failed: a hand-written plan is stale the moment anything moves, is lost with the session that wrote it, and exists at all only if someone remembered to write it.

Nothing the record needs dies with the agents.
Task metadata, worktrees, branches, merge posture, delivered instructions, and open captain calls are all on disk and all survive the wall untouched.
So `resume` regenerates the record from that state on demand, which is not merely as good as a pre-wall snapshot but strictly better: it cannot be stale, and it is available to a session that never saw the wall coming.

It composes rather than re-parses.
[`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) is the declared owner of structured fleet state and supplies identity, merge posture, current state, endpoint, pull request, and open captain calls.
The record adds only what that snapshot does not carry and a recovery needs: the branch, head, uncommitted and unpushed counts, the attributed pipeline run and its branch custody, and the steering records the worker has and has not acknowledged.
It is published whole or not at all, because a half-written record read during a recovery is worse than the previous complete one.

The record carries state and points at the skill for procedure.
That split is what keeps the two from drifting.

## Why attribution binds on branch and reports the head separately

The stranded shape is specific: `branch_sync.state` reads `pipeline_owned` and the run head is ahead of, or entirely absent from, the task's local copy, because the pipeline commits its fixes in its own gate copy.

[`bin/fm-nm-run-lib.sh`](../bin/fm-nm-run-lib.sh) owns the shared rule for binding a run to a worktree, and that rule requires the run head to be resolvable locally - which, in exactly this case, it is not.
Discarding the run there would hide the state a recovery most needs.

So `resume` and `diagnose` attribute on the run's branch and report the head relationship as evidence beside it: `equal`, `pipeline-ahead`, `pipeline-only`, or `diverged`.
They read the bare `no-mistakes axi` overview rather than `axi status`, because the overview is scoped to the invoking worktree's own run while `axi status` reports the repository's active-or-most-recent run - routinely another task's, on a repository with several worktrees validating at once.
This surface reports rather than acts, so naming the run and the relationship is the honest answer; acting on custody stays with the worker that owns the branch, under `AGENTS.md` section 7.

## Why the trigger is in the digest and not in anyone's memory

Knowledge that fires only when recalled is the failure being corrected, so the routing is printed on the observable condition rather than waited for.

- Before the wall, the session-start digest prints the gauge at the top of its live-fleet section, and `bin/fm-fleet-view.sh` prints it in the heartbeat review. Those are the two places a dispatch decision is actually made.
- At the wall, any endpoint the digest reads as not alive gets the cheap endpoint-only scan, and its verdict is printed beside the endpoint line with one shared pointer to the full diagnose and the skill.
- Mid-session, a dead or stale worker already routes through `stuck-crewmate-recovery` by an always-loaded contract, and that playbook's first step is now to rule out the wall.

A cheap scan that finds nothing reports `unknown`, never `no-signature`.
The 2026-08-23 evidence was in the step logs and not in the terminal, so a terminal-only negative is not a clean bill of health and must not read as one.

## Verification

[`docs/verification/usage-limits.md`](verification/usage-limits.md) records the dated empirical evidence: both gauge states against a real `quota-axi`, a record generated from real fleet state, and the endpoint-gone recovery proven end to end on a disposable task.
