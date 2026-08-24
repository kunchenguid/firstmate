---
name: task-grill
description: >-
  Agent-only requirements-interrogation stage of Firstmate's planning family.
  Load when `task-planning` routes a non-Simple ship request here at intake.
  Runs a frontier-based captain question loop until shared understanding is confirmed, and hard-gates spec, tickets, and implementation behind that confirmation.
user-invocable: false
metadata:
  internal: true
---

# task-grill

This skill interrogates requirements before anything is designed or built.
It is the first stage of the planning flow: `task-grill`, then optional `task-design`, then `task-planning`.
It rewrites Matt Pocock's `grilling` and `domain-modeling` methods for Firstmate's operating model.
Their artifact formats stay behind.
This file owns the Firstmate-native contract.

## Trigger

Load when `task-planning` classifies a ship request as non-Simple at intake.
A Simple request skips straight to the direct crew path and never runs this skill.

## Design tree

Map the request as a design tree: decisions branching off decisions.
Each node names one decision that must settle before the questions hanging off it can even be asked.
Start from the goal, name the load-bearing branches, and grow children only where an answer would genuinely change what gets built.

## Rounds and the frontier

Work the tree in rounds.
The frontier is every question whose prerequisites are already settled: everything answerable now without guessing at unheard answers.
Each round asks the whole frontier at once, questions numbered, each with a recommended answer.
End the round there and hold for the captain's answers before the tree moves again.
Answers reshape the tree: settled decisions push the frontier outward and unblock their dependents.
Recompute the frontier and ask the next round.
A question whose answer depends on a question still open in this round belongs to a later round, never this one.
Interrogation is done when the frontier is empty: every branch settled or explicitly discarded, nothing assumed in silence.

## Facts versus decisions

Facts are yours to find, never the captain's to supply.
When a frontier question needs repository evidence, read the target project clone directly.
When it needs broader investigation than a quick read, delegate one focused scout instead of asking.
Do not block the whole round on that investigation: only the questions downstream of it wait for the scout's report.
Only decisions go to the captain: preference, product policy, and trade-offs with genuine alternatives.
Never spend a round asking something you could look up yourself.

## Hard gate

While the frontier is not exhausted, or before the captain confirms shared understanding, spec, tickets, and implementation must not start.
This gate is not advisory: no downstream planning artifact may be written against unsettled decisions.
It was settled as captain decision D4 during this skill family's own planning.

## Captain answers stay human

Never answer a captain question on the captain's behalf.
A recommendation is not consent, and silence is not an answer.
Route every unresolved captain question through `captain-hold-lifecycle`, which owns the decision-hold contract.

## Artifacts

Write `docs/features/<feature-slug>/grill.md` in the target project clone, beside the other planning documents.
Keep three things in it:
- a snapshot of the design tree;
- the round log;
- the settled decisions.

Record terminology cleanups surfaced during grilling there as well.
Promote them into the project AGENTS.md `Domain terms` section at landing time through that project's normal delivery path.

## Domain modeling discipline

Grill the domain model while you grill the requirements.
Challenge glossary conflicts immediately: when fresh language contradicts recorded terms, surface the conflict now instead of shipping both meanings.
Sharpen fuzzy terms: propose a precise canonical name whenever wording is vague or overloaded.
Stress-test relationships with concrete scenarios that probe edge cases and force exact boundaries between concepts.
Cross-check stated behavior against the code and surface contradictions.
Offer an ADR only when all three hold:
- the choice is hard to reverse;
- it is surprising without context;
- it was a real trade-off with genuine alternatives.

If any is missing, skip the ADR.

## Handoff

When the gate passes, hand the confirmed understanding down the family: optional `task-design` for solution shaping, then `task-planning` for specification and ticket decomposition.
This skill ends at confirmed requirements and never writes the spec itself.
