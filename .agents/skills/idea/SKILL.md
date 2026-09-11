---
name: idea
description: Capture an idea instantly, or triage captured ideas through independent criticism and a compact decision table.
user-invocable: true
---

# Idea capture and triage

Use this skill for `/idea <text>` and `/idea triage`.

## Capture

For `/idea <text>`, run `bin/fm-idea.sh add "<text>"` and return the printed idea id without asking a follow-up question.

## Triage

For `/idea triage`, run `bin/fm-idea.sh triage` and use its printed path as the input for two or three blunt reader workers on different providers, choosing the cheapest available models.
Each reader worker fills the For, Against, Cost in minutes, Proposal, and Reason fields for every idea in its copy of the report.
After the reports return, run `bin/fm-idea.sh merge <triage-file> <critic-file>...` to produce one decision table.
Relay a compact table with id, idea, proposal, and reason to the owner.
The merge rule is unanimous kill becomes drop, unanimous bet stays bet, unanimous queue stays queue, and disagreement becomes queue with the disagreement in the reason.
Ask for one decision per line in the form `<id> bet`, `<id> queue`, or `<id> drop`.
Apply each answer with `bin/fm-idea.sh rule <id> <decision>` and pass `--until YYYY-MM-DD` for a queue resurface date or `--why "<text>"` for a drop reason.

Triage is on request only and never scheduled.
