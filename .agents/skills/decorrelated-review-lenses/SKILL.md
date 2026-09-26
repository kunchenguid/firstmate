---
name: decorrelated-review-lenses
description: >-
  Agent-only protocol for keeping an independently authorized review's successive rounds or parallel reviewers meaningfully independent.
  Use only while carrying out an authorized review or audit that actually has multiple rounds or reviewer fan-out.
  Owns the successive-round lens sequence and differentiated-reviewer-brief rule without adding a delivery gate.
user-invocable: false
metadata:
  internal: true
---

# decorrelated-review-lenses

Load this only while carrying out an independently authorized review or audit that actually has multiple rounds or reviewer fan-out.
Task lifecycle section 7 owns whether that review is authorized.
No-mistakes remains the sole owner of review, fixes, tests, documentation, push, PR, and CI when it is the selected delivery path.

## Current-path fit

The older proposal described every lens as a required review round and every same-artifact fan-out as mandatory.
That would stack a manual review gate onto no-mistakes or manufacture review work that was never authorized, so it is not retained.
Use these lenses to diversify an already-authorized review's coverage.
Do not require extra rounds, reviewer fan-out, or a manual clean verdict.

## Successive-round lenses

Apply the lens assigned to each round that the authorized review actually has:

1. **Round 1: cold read** - Read the artifact before the implementer's narrative, so that narrative cannot anchor the first pass.
2. **Round 2: execution** - Exercise the artifact, its tests, or its reproduction rather than only rereading it.
3. **Round 3 and later: contract audit** - Compare the result to the original intake requirements and acceptance criteria rather than the implementation's framing.

Do not invent rounds to exhaust the sequence.

## Reviewer fan-out

When an authorized review fans out reviewers over the same artifact, give them different briefs rather than copies:

- **diff-only** - Judge the change on its own terms.
- **full-context** - Read the change with surrounding code and history.
- **checkout-and-run** - Exercise the work in an isolated copy.

Agreement from differentiated lenses is more informative than agreement from identical briefs.
