---
name: worker-plan-roster
description: >-
  Agent-only procedure for the worker roster shown in the final approval step of a plan that will launch workers.
  Load before requesting the captain's approval of any plan that involves launching workers.
user-invocable: false
metadata:
  internal: true
---

# worker-plan-roster

This skill is the single owner of the worker roster presented immediately before the captain approves a plan that will launch workers.
`AGENTS.md` section 4 owns dispatch and model selection, section 7 owns authority and briefs, and section 9 owns captain-facing wording; this skill only says what the approval step must list.

## Procedure

1. Resolve every planned worker's concrete model and effort through the normal dispatch path before presenting the plan, so the roster states what will actually run rather than a placeholder.
2. Make the roster the last section of the plan, directly above the approval request.
3. List every planned worker, including coordinating, implementation, investigation, review, and validation roles, one row each.
4. Give each row the worker's bounded task in a short phrase, its concrete model, and its effort.
5. If a worker's model or effort is not yet resolved, say so in its row and resolve it before asking for approval rather than guessing.
6. Launch nothing until the captain approves; a changed roster needs a fresh roster and fresh approval.

## Shape

| Worker | Task | Model | Effort |
| --- | --- | --- | --- |
