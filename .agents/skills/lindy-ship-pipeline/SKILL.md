---
name: lindy-ship-pipeline
description: >-
  Agent-only hard-enforcement wrapper for shipping Lindy project work through the captain-ruled pipeline.
  Use before supervising, validating, merging, deploying, rolling back, or mirroring state for a Lindy PR or Linear ticket.
  It enforces the approved sequence without duplicating Lindy's project-owned skills: adversarial-review, watch-ci-review, Graphite merge queue merge, post-deploy fallout watch, and Linear state mirroring.
user-invocable: false
metadata:
  internal: true
---

# lindy-ship-pipeline

Use this skill before any Lindy shipping action that could move a PR, deploy state, rollback posture, or Linear ticket state.
This is a wrapper only.
It never replaces Lindy's project-owned skills, scripts, or command help.

## Authority Boundary

First locate and load the Lindy project's own instructions and the relevant project-local skills for each phase.
If the Lindy project does not expose a required phase owner, stop before acting and report that the shipping wrapper cannot prove the route.
Do not copy or reimplement Lindy's review, CI, Graphite, deploy, rollback, or Linear mechanics in Firstmate.
Do not infer that GitHub's visible approval state was erased just because the branch was force-pushed.
Approvals survive force-push unless the Lindy project owner or reviewer explicitly says otherwise.
Do not revert on-call Done states during Linear mirroring.
Write exactly one final evidence comment per ticket after the pipeline reaches its terminal state.

## Required Sequence

1. **Adversarial review.**
   Run the Lindy-owned adversarial-review workflow first and carry forward only its explicit required fixes, risks, and evidence.
   A stale or missing review is not a pass.

2. **CI watch.**
   Run the Lindy-owned `watch-ci-review` workflow after review requirements are satisfied.
   Treat CI as current only through that owner, not through a hand-rolled GitHub polling loop.

3. **Graphite merge queue merge.**
   Merge only through Graphite MQ with `gt merge` after review and CI are both green under the project rules.
   `gh pr merge` is forbidden for Lindy shipping, even when GitHub shows a green merge button.
   If MQ ordering is dependency-forced, record that fact in the ticket evidence.
   If serialization was avoidable, record the avoidable cause so the fleet dashboard can expose it later.

4. **Post-deploy fallout watch.**
   After merge, run the Lindy-owned post-deploy fallout watch.
   Use a fast-fail rollback posture: if the watch owner identifies a production fallout signature that meets rollback criteria, stop forward progress and initiate the project-owned rollback path immediately.
   Do not wait out the whole observation window after a rollback-grade signal appears.

5. **Linear mirroring.**
   Mirror the final state into Linear only after the deploy or rollback outcome is known.
   Preserve on-call Done states.
   Leave one final evidence comment on the ticket with review, CI, MQ, deploy or rollback, and fallout evidence links.

## Stop Conditions

Stop before acting if a step would require `gh pr merge`, a direct GitHub merge button, a hand-written CI poll, a local duplicate of the deploy fallout rules, or a Linear state change that would revert an on-call Done state.
Stop before acting if the PR needs a destructive rollback, security-sensitive credential, or human product call not already approved.
When stopping, report the exact missing owner, unsafe command, or decision needed.
