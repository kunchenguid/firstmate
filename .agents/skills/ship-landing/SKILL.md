---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
For a GitHub PR, load `pr-review-policy`, initialize its durable head-keyed ledger, and arm its delayed checkpoint in the existing watcher.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` and a passing current GitHub review-ledger generation are the only standing routine merge authorities.
Before applying Ready for QA after a GitHub merge or deploy, load `pr-review-policy` and satisfy its head-keyed post-merge gate without weakening any pre-merge browser check.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

## Batch landing

Batch landing through the in-house merge queue is the default when more than two review-complete pull requests wait on the same project and the project meets the preconditions in [`docs/merge-queue.md`](../../../docs/merge-queue.md), which owns the commands, lease and proof mechanics, and rationale.
With two or fewer waiting, or when a precondition fails, land each pull request through the ordinary path above.

1. Pick the batch in landing order: the order the captain set, otherwise dependencies first and then the order the pull requests became review-complete.
   A member is review-complete when its current review-ledger generation passes every gate and no human decision holds it.
   Its own head is green, or its only failures are ones the candidate run will disprove, such as a known flaky job.
   Record each member's full PR URL and head commit; a member whose head moves before it lands leaves the batch.
2. Build: steer the project's live landing crew with the members and heads in landing order, or dispatch one with `bin/fm-brief.sh <task-id> <repo> --landing-crew` and `bin/fm-spawn.sh <task-id> <project> --scout`.
   A member the crew drops for conflicting is refreshed alone by its own worker and joins a later batch.
3. Lease: when the crew asks, first confirm every member is still mergeable into the default branch, because the forge runs no CI on a conflicting head; drop a conflicting member to be refreshed alone and have the crew rebuild without it.
   Then grant exactly one push only while the project's concurrent full runs, including the default branch's own, are below the captain's cap; otherwise leave the request waiting.
4. Run: unless the project lands through member merges, open the batch pull request from `fm/batch-<n>` yourself after the leased push, counting the project's full runs again immediately before opening it because opening it starts the run the lease admits; only a green full run on the leased head proves the candidate.
5. Land the batch through the ordinary guarded merge path.
   Primarily, initialize the batch pull request's review ledger under the landing crew's task id with `bin/fm-pr-review.sh init <crew-task> <batch-url>` and complete it under `pr-review-policy` before merging.
   As the last step before merging it, confirm for every member that its head still equals its named head, no captain hold is open on its task, its review-ledger generation passes with no unreleased hold, and its own required checks are green or a current explicit captain waiver names the check, and confirm the default branch's head still equals the candidate's base; drop a failing member or rebuild on a moved base.
   Then merge the batch pull request once under the crew's task id with `bin/fm-pr-review.sh merge <crew-task> <batch-url>` when the reviewed-head handoff is required or the away-posture record exists, and otherwise `bin/fm-pr-merge.sh <crew-task> <batch-url>`; that records the batch pull request on the crew's task and arms its merge poll.
   After a batch pull request that was refused or abandoned without merging, rebind the crew with `bin/fm-pr-check.sh <crew-task> <next-batch-url>` before merging the next one, or the merge refuses with `bound to <old>, not <new>`.
   For a project that does not land through a batch pull request, merge the members in landing order instead, each on its own unchanged head.
   In either shape, a member still red on its own head waits for a rerun of only its failed job or a current explicit captain waiver naming that check, and never lands red, whether inside a batch pull request or by its own merge.
   If anything outside the batch lands on the default branch mid-batch, stop and put the unmerged members into a new candidate.
6. Close out: after a batch pull request squash- or rebase-merges, close each member pull request in its own repository (never by a bare number) with `Landed on main in batch PR #<n> (<sha>)`, only while its head still equals the head the batch carried, because the forge still shows every member open; a member whose head moved stays open and returns to the queue.
   Skip closing when the project merges with merge commits, since the forge then marks the members merged, and keep close-out resumable as `docs/merge-queue.md` describes.
   Tear down each member's task once its pull request is merged or closed as landed, and never the crew on a batch pull request's merged notification, which is informational; only the crew's own `done:` line and report end it.
7. Clean up: steer the crew to delete the remote candidate branch, which counts as done when the forge already deleted it, then hand it the next batch, built on the default branch as it stands after the latest merge, or tell it the queue is finished; tear the crew down after its report exists.

When a candidate run is red:

- A failure the base commit already has belongs to the default branch, so fix it there first and then rebuild.
- A flaky failure gets one rerun of the failed jobs on the same candidate head, admitted against the cap like a push.
- Otherwise bisect by halving: rebuild from the current default branch with the first half of the members in landing order, land that half when it is green and make the rest the next candidate, or halve again when it is red.
- A one-member candidate that is red identifies that member, which returns to its own worker for a fix and leaves the queue until its own head is green again.
- Never merge a member whose own head is red, whatever a candidate run shows.

Leave the record in the backlog: the landing crew's note lists each candidate's branch, head commit, proving run URL, members with full PR URLs, dropped members and why, and outcome, and each member's note names the batch, its batch pull request URL, or that it merged itself, and the proving run URL it landed with.

## Cleanup

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
