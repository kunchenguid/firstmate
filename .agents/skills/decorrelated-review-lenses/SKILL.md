---
name: decorrelated-review-lenses
description: >-
  Agent-only protocol for keeping review verdicts independent across rounds and across parallel reviewers.
  Use before commissioning a captain-authorized multi-round review and before fanning out parallel reviewers on the same artifact.
  Owns the per-round lens sequence and the differentiated-brief rule for reviewer fan-out.
user-invocable: false
metadata:
  internal: true
---

# decorrelated-review-lenses

Load this before commissioning a captain-authorized multi-round review, and before fanning out parallel reviewers on the same artifact.
It governs how such a review is structured, never whether one is authorized: section 7 still owns when a separate review is allowed at all.

## The problem

Reviews repeated with the same lens produce correlated verdicts.
Replaying round 1's lens at round 3 mostly rediscovers what round 1 already found, and identical briefs to parallel reviewers buy redundancy, not coverage.
Decorrelate deliberately, on both axes.

## Per-round lenses

Give each successive round of the same review a different lens:

- **Round 1** - a cold read of the artifact itself, before reading the implementer's narrative, so the narrative cannot anchor the reviewer's first pass.
- **Round 2** - real execution: run the artifact, its tests, or its reproduction rather than re-reading it.
- **Round 3 and later** - a strict audit against the original contract: the intake requirements and acceptance criteria, not the implementation's own framing of them.

## Per-reviewer briefs in fan-out

When several reviewers examine the same artifact in parallel, write each a DIFFERENT brief rather than copies of one brief:

- **diff-only** - the reviewer sees the change alone and judges it on its own terms.
- **full-context** - the reviewer sees the change with the surrounding code and history.
- **checkout-and-run** - the reviewer checks the work out and exercises it for real.

Identical briefs produce correlated verdicts; agreement between them is weaker evidence than agreement between decorrelated ones.
