---
name: task
description: >-
  Show one current, recent, or closed Firstmate task in enough detail to understand its purpose, outcome, dates, delivery state, artifacts, blocker or decision, and next action.
  Use when the captain invokes /task with a canonical id, active short reference, or human task name, especially before deciding whether to close completed work.
user-invocable: true
metadata:
  internal: true
---

# task

Require one selector, then run `bin/fm-task.sh --card <selector>` and return its stdout verbatim in a plain-text fenced block.
The central command resolves current canonical ids, active `t1`-`t99` references, and unambiguous human names through the same callsign owner as `/tasks`.
For work no longer current, canonical ids and unambiguous human names fall through to `/history` records, while retired short references deliberately remain unresolved.

[`docs/task-lifecycle.md`](../../../docs/task-lifecycle.md) owns the card's status, route, acceptance, and closure meaning.
Use `/tasks` (or bare `/t` in Pi) for the live fleet list, `/task <selector>` (or `/t <selector>` in Pi) for one item, `/next` for the next forward lifecycle action, `/close --review <selector>` for a closure preview, and `/history` for closed work.
Do not supplement or reinterpret the card from raw task records unless the captain explicitly asks for a deeper investigation.
