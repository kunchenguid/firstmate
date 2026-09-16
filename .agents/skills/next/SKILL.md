---
name: next
description: >-
  Identify the single highest-value captain action that can restart work, or one completed task to close only when no work can move forward.
  Use when the captain invokes /next or asks for the one most important thing to address next.
user-invocable: true
metadata:
  internal: true
---

# next

Return one opinionated decision card, not a fleet digest or a list of possibilities.
The goal is to restart useful work as quickly as possible.

Run `bin/fm-next.sh` once and return its plain-text output verbatim.
Do not re-rank, paraphrase, supplement, or carry out the card's actions during the `/next` invocation.
The command composes the canonical fleet snapshot and owns eligibility, ranking, current-state resistance, closure fallback, JSON structure, and the exact plain-text card.
Its header and `--help` own the executable contract.
Use `bin/fm-next.sh --json` only when structured output is explicitly needed for debugging or another deterministic view.

If the command says `Fleet needs no captain action.`, return that sentence without inventing proactive work.
If collection fails, report the concrete failure rather than guessing from conversation history or the latest task event.

## Relationship to task commands

- `/tasks` is the fleet-wide table for surveying and comparing work.
- `/task <ref>` opens the durable detail for one task.
- `/next` selects one action from current task and worker truth and explains why it outranks the rest.
- `/close <ref>` accepts the selected completed task's end and moves it out of the closure queue without creating follow-up work.
- `/history <ref>` retrieves work after closure.

Use `/tasks` for breadth, `/task` for depth, `/next` for focus, `/close` for explicit completion, and `/history` for recall.
A `/next` closure recommendation never authorizes new follow-up work.
