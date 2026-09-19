---
name: plan-breakdown
description: Build and approve an implementation plan from an explicitly aligned specification.
user-invocable: false
metadata:
  internal: true
---

# Plan breakdown

Load after explicit intent alignment and before implementation dispatch.
Read the spec by stable alignment key and stop if intent or scope still needs a decision.
Use the scaffolded plan template beside that spec.
Carry over its validation criteria and cite settled D-numbers rather than duplicating decisions.

Describe WHAT each atomic unit delivers, not pre-written code or an imposed implementation recipe.
Assign stable U-numbers that survive reordering; never renumber existing references.
Each unit names its outcome, acceptance evidence, dependencies, and linked work item.
Keep units independently implementable and testable where possible; distinguish true semantic dependencies from file overlap.
Record guardrails, explicit out-of-scope work, risks, and open points.
Resolve open product decisions through align-intake before calling the plan approved.
Obtain explicit plan approval and record the actual words and date, then set the plan status to approved.
For the eligible trivial lane, cite the bounded instruction that already approves the single unit.

Use `bin/fm-alignment.sh link` for each execution item, and generate its brief with `bin/fm-brief.sh --alignment <key>`.
The alignment script's header owns the machine-consumed record format and command syntax.
Implementation follows existing delivery and validation rules; changes to accepted intent return to alignment rather than silently expanding units.
After validation, route durable knowledge through align-intake's record routing table.
