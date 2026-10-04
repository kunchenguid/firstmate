---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.

## Slicing large work

When a scout plans work too large for one ship, slice it into vertical tracer-bullet slices.
Each slice cuts a narrow but complete path through every layer it touches, is demoable on its own, and fits one fresh context window.
Declare each slice's blocking edges, the earlier slices that must land first, so the frontier of takeable work is explicit.
Serialize only across a true semantic dependency as `AGENTS.md` section 7 defines it.
A wide refactor whose blast radius cannot land green as a vertical slice uses expand-contract: add the new path beside the old, migrate in batches, then delete the old, possibly on a shared integration branch.

## Prototype deliverable

When a design question cannot be settled in prose, a scout may deliver a prototype: throwaway code that answers that one question.
Throwaway constrains how the code is written, not whether it survives.
The report names the prototype branch and says it is preserved there as a primary source that outlives the scout's worktree.
Before teardown the scout leaves the prototype branch not checked out and returns the worktree with the default branch checked out, because teardown force-deletes a branch that is still checked out.
The validated decision folds into the real code on the ship that follows.
A prototype never becomes a PR, because a scout never produces one, and it does not authorize implementation.
