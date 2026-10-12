---
name: audit-brief
description: >-
  Agent-only standard for exact-scope audit briefs: bounded initial scope with a mandatory expansion clause, reading budgets as effort guidance, and lean carry-forward context.
  Load before scoping, writing, or dispatching an audit brief, and when composing the objective or context an audit-stage consultation sends.
user-invocable: false
metadata:
  internal: true
---

# audit-brief

Audits here are context-bound by measurement: about 98.5% of a peak audit request was re-sent conversation rather than new reading, so the first wins are carrying less forward and starting smaller - never narrowing what evidence may be followed.
Document splitting and new navigation maps stay out of scope until a measured pilot shows a net benefit.

[`audit-brief-template.md`](audit-brief-template.md) is the single owner of the contract, and `bin/fm-chatgpt-consult.sh` injects that same file into its audit-stage instructions, so ChatGPT-generated audit prompts follow it without a second copy living in the script.

## Writing an audit brief

1. Use the template's sections as the build instructions in the task's `## Firstmate spec`, with the captain's own ask as `## Captain's intent` unchanged; scope statements belong in the spec because the reviewer treats intent as acceptance criteria.
2. Name exact initial scope honestly: files, symbols, line ranges, invariants, dependencies, and the verification each finding needs; write "none" for available maps rather than promising to build them.
3. Keep the initial payload small: state only the context needed to read the ask, give referenced reports and prior findings as their distilled substance with the source cited by path, and never paste a prior report or a background block into the brief.
4. Carry the template's expansion clause and carry-forward discipline into the brief text itself, because a worker in a project worktree cannot rely on reading this repository later.

## Non-negotiable safeguards

- The brief's file list is never a whitelist: the worker follows credible evidence anywhere, and an audit that stops at the list is a failed audit.
- Fewer findings are never reported as efficiency; every saving is measured against missed defects.
- Raw evidence stays in files or logs referenced by path, and no change may discard the only copy of an observation.
- Reading budgets guide effort and never cap evidence-following.

## Out of scope here

- Document splitting, new navigation maps, and phase-splitting machinery are later steps that only a measured pilot with a quality comparison can justify.
- Per-turn token savings remain hypotheses until a controlled comparison measures them; claim only savings that were actually measured.
