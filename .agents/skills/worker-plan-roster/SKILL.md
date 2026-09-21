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

1. Resolve every planned worker's launch-effective model and effort through the normal dispatch path and the selected harness reference before presenting the plan.
2. Prefer an explicit model or effort value that the adapter will pass to the harness.
3. When an axis must remain omitted, verify the exact harness default from its authoritative current discovery surface and write it as `default (<value>)`; an omitted value or an unsupported value recorded only in task metadata is not a concrete runtime value.
4. If a requested effort will be recorded and omitted, show both the effective default and the metadata-only request in the effort cell.
5. Do not ask for approval while either launch-effective value is unknown; select a dispatch whose values can be resolved or report the blocker.
6. Make the roster the last section of the plan, directly above the approval request.
7. List every planned worker, including coordinating, implementation, investigation, review, and validation roles, one row each.
8. Give each row the worker's bounded task in a short phrase, its launch-effective model, and its launch-effective effort.
9. Launch the approved roster with those exact values, and re-resolve any omitted-axis default immediately before launch.
10. Launch nothing until the captain approves; any change to the worker set, task, model, or effort, or a default that can no longer be verified, needs a fresh roster and fresh approval.

## Shape

| Worker | Task | Model | Effort |
| --- | --- | --- | --- |
