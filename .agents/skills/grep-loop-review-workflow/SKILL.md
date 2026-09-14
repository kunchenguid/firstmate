---
name: grep-loop-review-workflow
description: >-
  Agent-only procedure for a bounded, evidence-based review of a small Firstmate change or pull request.
  Use only when a separate review or review re-check loop is explicitly requested, not for ordinary no-mistakes delivery.
metadata:
  internal: true
---

# grep-loop-review-workflow

Use this skill for a focused review of a small change or pull request when Firstmate has explicitly requested that separate deliverable.
The review loop collects evidence, classifies findings, and re-checks later revisions after their owner applies accepted fixes.
It does not apply fixes itself.

This is a review procedure, not a delivery or orchestration system.
It never creates or edits a pull request, pushes, merges, creates a worktree, dispatches a crewmate, starts a background process, or polls a monitor.
Firstmate and the selected delivery path own implementation, supervision, delivery, and merge authority.

## Routing and authority

Use this skill only when the captain explicitly requests a separate review or audit, or when the authorized task is a knowledge-only review.
Keep the review to one named question and a bounded change set.
If the task is using `no-mistakes`, do not start a parallel manual review loop because no-mistakes owns review, fixes, tests, documentation, push, pull request, and CI.
While a no-mistakes run is active, follow its installed skill and live `axi` help, and never hand-edit, commit, or restart the run to address a review finding.
An ambiguous product, destructive, security-sensitive, or scope-expanding finding is returned to Firstmate as a decision or follow-up, not answered by the reviewing crewmate.

A review-fix loop means that the review is repeated after the authorized owner supplies a new revision.
It does not authorize the reviewer to edit code or answer a merge decision.
A clean review is evidence about the reviewed revision, not merge authority.

## Collect the review evidence

1. Record the target, the named review question, the revision or commit being reviewed, and the allowed scope before reading feedback.
2. Confirm that the change is small enough for a reliable review.
   If it is too large, report the boundary and suggest a split without splitting it or changing the branch.
3. Read the complete diff before deciding whether feedback is valid.
4. For a pull request, use `gh-axi` for every forge read:
   `gh-axi pr diff <number> --full`, `gh-axi pr view <number> --comments --reviews --full`, and `gh-axi pr checks <number>`.
5. Read every issue-level, review-level, and inline reviewer comment returned for the revision.
   Treat AI reviewer comments as first-class evidence, while ignoring deployment previews and status mirrors unless they contain an actual finding.
6. Treat required checks as a second reviewer.
   A failing required check blocks a clean verdict, and an in-progress check is not green.
   A suspected flaky or unrelated failure is recorded as a blocker for Firstmate rather than waived or fixed speculatively.
7. For a local change without a pull request, use the caller-provided branch and repository diff evidence instead of inventing forge state.

## Evaluate findings

Check each finding against the current diff, the requested behavior, the surrounding code or documentation, and relevant test evidence.
Record the exact file and line when available, the observed evidence, the impact, and whether the finding is confirmed, unsupported, environmental, or awaiting a decision.
Keep only findings that are real and relevant to the named scope.
Do not broaden the review into an unrelated cleanup or rewrite.
Do not treat an approval or a clean automated check as proof that every concern is resolved.

When the owner supplies a new revision, repeat the diff, complete-feedback, and check collection for that revision.
Compare the new result with the previous finding set so resolved findings, regressions, and newly introduced findings remain distinguishable.
Do not wait in a background loop for a revision or a check to change.

## Firstmate handoff

Return a compact report containing the target, revision, named question, scope, findings ordered by severity, evidence for each finding, check status, and unresolved decisions or blockers.
State `clean` only when the reviewed scope has no material findings and every required check is green.
State `not clean` when a material finding remains or a required check is failing or pending.
If an authorized owner needs to apply a fix, return the finding to the Firstmate-owned workflow instead of editing it here.
Do not post the report or a review submission automatically; provide the report for the caller to route through the appropriate Firstmate channel.
