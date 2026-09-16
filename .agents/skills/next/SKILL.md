---
name: next
description: >-
  Identify the single highest-value captain action that can restart work or advance review, acceptance, delivery, or monitoring, with closure only when no forward lifecycle action remains.
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
The command composes the canonical fleet snapshot with the captain-facing projection and owns eligibility, ranking, current-state resistance, closure fallback, JSON structure, and the exact plain-text card.
[`docs/task-lifecycle.md`](../../../docs/task-lifecycle.md) owns status, route, acceptance, and closure meaning, while the command header and `--help` own executable mechanics.
Use `bin/fm-next.sh --json` only when structured output is explicitly needed for debugging or another deterministic view.

If the command says `Fleet needs no captain action.`, return that sentence without inventing proactive work.
If collection fails, report the concrete failure rather than guessing from conversation history or the latest task event.

Use `/tasks` for breadth, `/task` for depth, `/next` for focus, `/close` for guarded archival, and `/history` for recall.
A `/next` recommendation records or explains one lifecycle action only and never supplies acceptance, delivery, closure, or follow-up authority by itself.
