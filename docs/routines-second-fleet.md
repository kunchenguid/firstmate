# Routines as a second fleet

A Routine is a Claude Code session that a cloud timebase starts on a schedule, outside every Firstmate home.
Firstmate's own scheduler is unchanged and remains primary: a registered custom check gates the work, `bin/fm-brief.sh` and `bin/fm-spawn.sh` create it, and the project's delivery mode and merge authority land it.
A Routine is a secondary path for the narrow case where that primary path is unavailable or where the work never needed an interactive primary at all.

This page is the allowlist policy for that second path.
Nothing here is armed by default, and a home with no approved Routine is the normal, expected state.

## Who may create a Routine

The captain creates a Routine in their own Claude account.
Firstmate never creates one, and a brief never asks a worker to create one.

The delegation guard in [`subagent-guard.md`](subagent-guard.md) denies every cron-shaped and schedule-shaped tool name in a primary home, and that denial stands unchanged.
Wanting a Routine is not a reason to relaunch a session with `FM_ALLOW_SUBAGENT=1`.
That guard is deliberately inert inside a crewmate's disposable worktree, so routing a schedule registration through a worker would bypass it; that bypass is forbidden by this policy rather than by the hook.

## Eligibility classes

A Routine may exist only when it fits one of the classes below and the captain has approved that named job.
The class is necessary and never sufficient, because approval is always per job rather than per class.

| Class | What it may do | Ceiling |
|-------|----------------|---------|
| R1 read-only report | Read a repository, a public surface, or its own scheduled input and report to the captain's own Claude surface | Writes nothing anywhere |
| R2 draft-only change | Prepare a change and leave it as an unmerged branch or pull request on a repository whose standing posture allows an automated draft | Never merges, never pushes to a default branch, never releases |
| R3 off-fleet work | Personal or cloud work with no Firstmate home, product runtime, customer surface, or credentialed account in its blast radius | Touches no fleet or product state |

Prefer the lowest class that does the job, and prefer R1 for a first Routine in any new area.

## Standing denials

These hold for every class and every approved job, and only a later explicit captain word for one named job can move any of them.

- No merge, and no release, tag, or deploy.
- Nothing touching a repository whose posture holds merges for explicit captain word, including any change to `tradingview-tools`.
- No money, no publishing to a public surface, and no use of a credentialed vendor account.
  Preparation may be scheduled; the publish stays held.
- Nothing destructive, irreversible, or security-sensitive, and no secret carried in the Routine's own prompt or output.
- No liveness or watchdog duty.
  The Studio deadman in [`deadman.md`](deadman.md) stays the single liveness path, and a Routine never replaces, supplements, or silences it.
- No fleet supervision or dispatch.
  A Routine never writes into a Firstmate home's records, queues, or backlog, never steers a worker, and never decides what the fleet does next.

## Declaration

Every proposed Routine is written down in this shape before it is approved, and a proposal that cannot fill every field is not ready.

| Field | Meaning |
|-------|---------|
| Class | R1, R2, or R3 |
| Owner | The home whose backlog carries this job's failures |
| Seam | Always the cloud Routine seam, recorded so the placement stays visible next to the fleet's other schedules |
| Cadence | How often it runs, inside the account's own run budget |
| Blast radius | Every repository, surface, and account the run can reach, and the worst outcome of a wrong run |
| When Firstmate is down | Whether the job skips, queues, or is exactly the reason it exists |
| Kill metric | The observation whose absence retires the job |
| Removal | The one action that removes it, and anything left behind afterwards |

Green is silence.
A Routine that reports on an uneventful run trains the captain to ignore it, so report only when something needs a human.

## Approval, record, and retirement

The captain approves each named job explicitly, and that approval is recorded as a captain decision in the owning home's own records rather than in this repository.
This page carries the policy; the roster of live jobs is home-local, because it is fleet-private and differs per operator.

Failures belong to the owning home's backlog like any other work.
Retire a Routine when its kill metric goes quiet, when the primary path can do the job again, or when any standing denial above turns out to be in tension with what the job actually does.
Retirement is deleting the schedule in the Claude account, which is why every approved job must be reversible in exactly that one step.

## Worked example: a safe first Routine

This is the shape of a first job, and it is deliberately the least powerful useful one.

**Fork drift watch.**

| Field | Value |
|-------|-------|
| Class | R1 read-only report |
| Owner | The primary home |
| Seam | Cloud Routine |
| Cadence | Once daily |
| Blast radius | Read-only access to the operator's own Firstmate fork and its upstream; no write anywhere, no credential, no product surface |
| When Firstmate is down | Runs anyway, which is the point; the report waits in the captain's Claude surface |
| Kill metric | The operator still maintains a long-lived fork meant to track upstream, and the captain has not withdrawn that intent |
| Removal | Delete the schedule in the Claude account; nothing else to unwind |

The job reads the fork's default branch and its upstream and reports only when the fork has fallen behind, naming what landed upstream.
It opens nothing, pushes nothing, and merges nothing, so a wrong run costs one unnecessary message.

For a silent R1 job, the kill metric has to be an intent-still-holds check rather than a count of captain actions, because green is silence and a healthy run produces none.
Its silence means only that no drift was found.
It is not evidence that Firstmate is alive, and reading it that way would quietly substitute a report for the deadman.
