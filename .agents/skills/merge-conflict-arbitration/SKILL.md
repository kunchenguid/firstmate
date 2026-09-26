---
name: merge-conflict-arbitration
description: >-
  Agent-only protocol for an independent resolver to reconcile an actual semantic merge or rebase conflict between parallel contributions.
  Use only after the selected delivery path reaches that conflict, not because two tasks share a file.
  Owns the independent resolver, verbatim-intent inputs, the three-class semantic-decision taxonomy, the conflict-regions-only rule, and the resolution record.
user-invocable: false
metadata:
  internal: true
---

# merge-conflict-arbitration

Load this only when the selected delivery path reaches an actual semantic merge or rebase conflict between parallel contributions.
Same-file overlap alone is not a trigger, because task lifecycle section 7 owns when independent work may proceed and how ordinary reconciliation happens.
This protocol prepares a resolution without changing the selected delivery path or merge authority.

## Current-path fit

The older proposal required the merge authority to receive every same-question choice for veto before the resolution landed.
That would add a manual approval gate outside the current delivery path, so it is not retained.
Record the decision summary with the normal resolution or PR evidence for the existing authority to review.
The resolver must select one answer whenever the intent evidence distinguishes the competing answers.
Escalate for the captain's choice only when the intents genuinely tie and support incompatible answers.

## Independent resolver and inputs

The resolver must not have authored either contribution.
Give that resolver both conflicting diffs and both intents verbatim.
Intent means the contribution authors' own words from task instructions, PR bodies, or, only when neither is available, commit messages.
A resolution based on diffs alone guesses at intent and is not arbitration.

## Semantic-decision taxonomy

Within every conflicted hunk, treat each question or independently intended change as a separate decision and classify each decision into exactly one class:

- **disjoint-intent** - The contributions answer different questions in the same region, so combine both changes.
- **same-question-different-answer** - The contributions answer the same question differently, so select the one answer better supported by the stated intents and do not synthesize an unrequested hybrid; if the intents genuinely tie and support incompatible answers, escalate for the captain's choice.
- **superseded** - One contribution makes the other obsolete, so retain the surviving contribution.

## Resolution boundary and record

Change only conflict regions.
Do not refactor, restyle, or improve non-conflicting code while resolving the conflict.
Record every decision's class, selected result, and intent evidence with the normal resolution or PR evidence.
