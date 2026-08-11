# Fast Repair

Fast Repair is an opt-in, per-task delivery exception for a confirmed narrow repair.
It does not change a project mode, its normal dispatch, its merge policy, or the handling of requests without the Fast Repair prefix.

## Invoke it

Use the exact request prefix `fast-repair: ` followed by the repair request.

Example:

```text
fast-repair: Correct the Secretary search result count after deleting one local draft.
```

`fast-repair:` without a following request, `Fast-repair:`, `fast repair:`, and `fast-repair :` do not activate Fast Repair.

The prefix requests an eligibility decision for that task only.

## Eligibility

Fast Repair requires typed evidence for all of these positive facts:

- A known end-user reproduction.
- A confirmed root cause.
- A narrow, isolated code change.

The intake values are exact: `--reproduction reproduced`, `--root-cause confirmed`, and `--isolation isolated`.

It also requires each of these exclusions to be explicitly `none`:

- Schema or migration change.
- Authentication change.
- Permission or authorization change.
- Secret handling change.
- Financial behavior change.
- Legal or compliance behavior change.
- External side-effect change.

An absent, empty, unknown, ambiguous, false, or otherwise different value refuses Fast Repair.
Agent confidence is not evidence.
The refusal names the condition that was not proven, and the request returns to normal intake with the project's existing delivery rules.
An eligible Fast Repair does not create a scout or add plan, design, CEO, engineering, or other review workflows.
A scout cannot be promoted into Fast Repair either, because eligibility needs a known end-user reproduction and its typed record at normal intake.

The exact typed interface and evidence record are owned by `bin/fm-fast-repair.sh --help`.

## Delivery

Eligible work uses the built-in Codex profile `gpt-5.6-luna` with `medium` effort.
An explicit conflicting task profile refuses instead of being replaced.
A raw launch command also refuses because it cannot prove that canonical profile.
The task always has `yolo=off`, so captain approval remains the only merge authority.
Fast Repair never enables auto-merge.

The repair must add a regression test that reproduces the defect and must pass focused module tests.
`bin/fm-fast-repair.sh evidence` executes and records both gates.
The only supported interface is the tracked `bin/fm-test-run.sh` runner and named families from its `--list-families` output: the regression family, a different focused family, and later a broader family.
The recorded pre-fix reproduction commit must be an ancestor of the tested head.
Fast Repair identifies exactly one new test artifact from the regression family's runner-owned selector, overlays that artifact onto an isolated reproduction checkout, and requires that selected artifact to fail there and pass at the tested head.
The evidence record binds the selector, test artifact identity, reproduction revision, tested revision, and both results.
Projects without this runner, its selector overlay support, or this proof refuse Fast Repair evidence.
Missing or failed evidence blocks direct PR publication.

At dispatch the task worktree holds no repair yet, so the spawn gate proves only that it is a clean worktree of the task's own repository whose history already carries the recorded reproduction commit.
That worktree is still at a detached HEAD then, because the crewmate creates its `fm/<id>` branch as its first action.
The branch binding and the requirement that the reproduction commit be strictly older than the tested commit are proofs about the tested head, so every gate after dispatch enforces them.
A relaunch replaces a wedged crewmate in a worktree that already holds unlanded repair work, so it skips that dispatch-time clean-worktree proof; the typed eligibility gate that runs on every Fast Repair spawn still refuses a relaunch whose authorization record is gone or no longer valid.
The recorded reproduction revision is a lowercase commit id of 40 or 64 characters, so both git object formats are supported.

After those gates pass, `bin/fm-fast-repair.sh publish-pr` opens and registers the direct PR immediately.
The worker then starts one supported broader runner family while the new PR's checks run concurrently.
The broader family must differ from the focused family, because the focused module was already proven before the PR opened.
Re-running the focused family as the broader gate is refused, and `ready` re-applies that same rule to the stored broader record.
The task worktree must be clean and exactly at its tested revision before focused, regression, or broader evidence can run.
Every selected focused and broader artifact must be tracked, regular, inside that worktree, and unchanged at the tested revision.
Broader-test failures are recorded and surfaced as an open PR that is not green.
The Fast Repair progress check also surfaces failed PR checks.
A PR is not called ready or green until the broader test and all required PR checks pass.
`ready` prints the exact check counts it approved on.
A rollup where no check passed is never green, because the forge reports a cancelled check as a skipped one.

The Fast Repair progress check runs about every 20 seconds only while durable task metadata records an eligible Fast Repair task.
The timer runs during the existing watcher wait, so it does not change ordinary task polling, stale handling, pane scans, backend capture cadence, backend transition budgets, or global defaults.
A changed result found by that timer interrupts whichever wait the watcher is in, including the backend event and push-transition wait, so it reaches the captain in the cycle it was found rather than at the end of the poll budget.
A result identical to the one already surfaced never interrupts a wait, so an unchanged Fast Repair state costs no extra supervision cycles.
A progress check that is stopped at a poll boundary keeps its due time, so the beat is retried on the next tick instead of being skipped for a whole interval.
That is a retry guarantee, not a delivery one: a forge call slower than the remaining poll window is reaped before it can publish, and the ordinary PR check poll stays the backstop.
Once the first green rollup is queued the cadence stops polling the forge for that task, and the ordinary PR check poll owns its PR checks from then on.
The task-scoped beat continues in a local-only form that reads only this home's own broader-test record, so a broader failure landing after the rollup turned green is still surfaced.
That local follow-up ends once the broader family reaches its terminal result and that result is surfaced; the beat then retires entirely and the ordinary lifecycle and PR polling own the task.
A progress result the wake queue refuses stays on disk for a later cycle to retry, but it stops shortening waits after its bounded attempt budget, so a degraded queue cannot turn every watcher wait into a zero-length one.
A relaunch of a Fast Repair task reuses the recorded profile, so the standard recovery command needs no profile flags.

## Examples

Eligible request:

```text
fast-repair: Fix an off-by-one count in the already reproduced Secretary deletion view; the root cause is one stale in-memory filter, the one-module patch has no schema, auth, permission, secret, financial, legal, or external-effect change.
```

Refused request:

```text
fast-repair: Add an audit field when a Secretary record is deleted.
```

This is refused because it changes schema and external behavior, so it follows the normal project path.
