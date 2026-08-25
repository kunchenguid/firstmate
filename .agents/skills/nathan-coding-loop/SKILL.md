---
name: nathan-coding-loop
description: >-
  Agent-only procedure for mandatory second-mate coordination of tracked code changes.
  Load before routing, starting, or coordinating work that will change tracked code, and keep it loaded through the independent review loop.
  Requires a PR-owning implementation worker and a separate read-only reviewer to alternate fixes and complete-diff review until the current PR head has no material findings, without granting merge authority.
user-invocable: false
metadata:
  internal: true
---

# Second-mate code review

Load this skill before routing, starting, or coordinating work that will change tracked code.
This skill is the single procedure owner for the mandatory second-mate developer-reviewer loop.
The selected delivery path still owns implementation, validation, push, and PR mechanics, and `AGENTS.md` still owns merge authority.

## Scope and routing gate

This loop applies when authorized work will change tracked executable source, scripts, behavioral configuration, workflows, or tests.
Documentation changed as part of such work stays in the same loop.
A prose-only task remains under the ordinary task lifecycle unless it also changes executable behavior.

The main firstmate routes the complete work item to a fitting second mate rather than directly commissioning the implementation or review.
Use an existing scope-compatible second mate when one is available.
If none is available, load `secondmate-provisioning` and establish an appropriate persistent second mate before work starts.
A missing viable second-mate route is a blocker to escalate, not permission for the main firstmate to coordinate the loop itself.

The task must have a viable GitHub PR path using its already selected `no-mistakes` or `direct-PR` delivery mode.
A selected `local-only` mode, unavailable forge, missing push permission, or branch that cannot update its task PR is a blocker to escalate before implementation proceeds.
Do not silently downgrade, bypass the review, or invent a parallel delivery path.

## Roles and independence

The second mate is the coordinator and must not implement or review the change itself.
It commissions at least these two separate workers:

- One implementation worker owns the task branch and the selected PR delivery path.
- One independent reviewer owns read-only review of the PR and must not edit code, commit, push, run a fix agent, or operate the implementation worker's validation pipeline.

The implementation worker cannot review or approve its own work.
The reviewer must be a different agent in a different isolated task context and must not have authored any part of the task branch.
Keep the same implementation worker and reviewer through every round when they remain viable, because continuity makes disagreements and regressions explicit.
If either worker must be replaced, preserve the task records and require the replacement reviewer to inspect the complete current diff from the beginning.

Use the normal brief, spawn, dispatch-profile, supervision, steering, recovery, and cleanup contracts for both workers.
Scaffold the implementation as a ship using the selected PR mode.
Scaffold the reviewer as a scout, then make its task-specific instructions retain the no-code rule, the full-diff protocol below, the GitHub comment requirement, and the iterative wait for later heads.
Do not weaken either generated scaffold's safety sections.

## Establish the one task PR

Before the implementation worker opens anything, inspect the task's durable records and query GitHub with `gh-axi` for an existing open PR for its branch.
If the task already has a PR, give that full URL to the implementation worker and require updates to that PR.
If it does not, the implementation worker creates exactly one PR through the selected delivery path.
Never open a second PR to represent a fix round or review round.
If multiple plausible task PRs exist or the worker cannot update the existing PR, stop and escalate the ambiguity.

For `no-mistakes`, the implementation worker owns the complete gate interaction and reports once the PR checks are green.
For `direct-PR`, the implementation worker pushes and opens or updates the PR with `gh-axi` under the normal direct path.
After a PR exists, register it through the normal PR-check path so the task record follows the current forge head.
The reviewer never starts until the PR URL and exact current head are known.

## Independent complete-diff review

For each review round, the reviewer must independently obtain the current PR head and inspect the complete branch diff against the PR's authoritative base.
Use `gh-axi pr view`, `gh-axi pr diff --full`, and repository reads as needed rather than relying on the implementation worker's summary or only the commits since the prior round.
If using `bin/fm-review-diff.sh`, treat its local-branch fallback warning as insufficient for a conclusive review and escalate unless the PR head can be independently resolved.
Record the exact reviewed head SHA in the review report.
Re-read the PR head after the review, and restart the complete-diff review if it changed during inspection.

Review the actual changed behavior, tests, documentation, and integration boundaries.
Verify consistency with the repository's existing lifecycle, delivery-path, and merge-authority contracts, including their authoritative scripts, skills, and tests rather than prose recollection.
Inspect every affected supported harness and runtime integration surface required by `firstmate-coding-guidelines`.
Mark an axis not applicable only after inspecting the integration surface and record the reason in the review report.

A material finding is a concrete defect in accepted intent, correctness, safety, security, lifecycle behavior, delivery-path behavior, merge-authority preservation, compatibility, tests, or required documentation.
For every material finding, post an evidence-backed line-specific GitHub review comment through `gh-axi` against the reviewed head.
Consult current `gh-axi api --help` before posting and use the GitHub pull-request review-comment endpoint with the PR repository, pull number, current commit id, changed-file path, diff line, side, and body supplied explicitly.
The comment body states the observed evidence, consequence, and required correction.
Never post a summary-only issue in place of the required line-specific comment.
If a material concern cannot be anchored to a relevant changed line, report that limitation to the second mate instead of fabricating a line location, keep the review round open, and escalate before completion.

Do not post nits, praise, acknowledgements, or placeholder comments.
A clean review produces no GitHub comment merely to prove the review happened.
The reviewer reports `no material findings` to the second mate with the PR URL, reviewed head SHA, inspected surfaces, and validation evidence in its scout report and completion status.
The reviewer does not submit a GitHub approval, because reviewer satisfaction is evidence for the coordinator and never merge authority.

## Alternate fixes and review

When the reviewer posts material findings, the second mate sends the complete finding set to the same implementation worker.
The implementation worker resolves the findings on the existing task branch, updates the existing PR through the same selected delivery path, and returns the new exact head only after that path's required validation is complete.
For `no-mistakes`, branch custody and every fix or rerun remain governed by the installed no-mistakes procedure and the task lifecycle in `AGENTS.md`; neither the second mate nor reviewer edits around an active run.

The same reviewer then fetches the new head and performs another complete-diff review against the authoritative base.
Reviewing only the latest fix commit, only previously commented lines, or only the developer's response is not sufficient.
Repeat developer fixes followed by a fresh complete-diff review until the reviewer explicitly reports `no material findings` for the unchanged current PR head.
A reviewer dispute or unavailable line target goes to the second mate for resolution or escalation and never becomes a reviewer code edit.

## Completion and authority

The second mate may report the PR ready to the main firstmate only when all of these are true:

- The implementation worker's selected PR delivery path is complete for the current head.
- The reviewer explicitly reported `no material findings` for that same head.
- Every material comment from earlier rounds is addressed by the current diff or explicitly resolved without bypassing accepted intent.
- The PR remains unmerged.

Report the full PR URL, current head, selected path result, review-round count, and the reviewer's clean conclusion.
Do not translate reviewer satisfaction into approval to merge.
The captain's explicit approval or the project's standing `yolo` posture remains the only routine merge authority, and destructive, irreversible, security-sensitive, and red-check boundaries remain unchanged.
Neither the second mate nor either worker merges the PR as part of this loop.
