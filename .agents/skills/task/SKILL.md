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

Use `/tasks` for the compact fleet list, `/task <selector>` to understand one item, `/close --review <selector>` to preview archival, `/close <selector>` to acknowledge and archive completed work, and `/history` to browse or search work already closed.
Do not supplement or reinterpret the card from raw task records unless the captain explicitly asks for a deeper investigation.
