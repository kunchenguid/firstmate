---
name: task-lifecycle
description: >-
  Record review, acceptance, delivery, monitoring, or a return to work for a Firstmate task.
  Use when the captain starts or finishes review, accepts a candidate and selects its route, records delivery or monitoring evidence, or sends a result back for correction.
user-invocable: true
metadata:
  internal: true
---

# task-lifecycle

[`docs/task-lifecycle.md`](../../../docs/task-lifecycle.md) is the single owner of captain-facing statuses, routes, acceptance, and closure prerequisites.

Resolve the named task through its canonical id, active short reference, or human name, then use exactly one guarded `bin/fm-task-lifecycle.sh` transition that matches the captain's action.
Pass the actual acceptance actor, evidence, limitations, and selected route without inferring them from tests, completion, delivery, or prior conversation.
Use `return-to-work --reason <text>` for a review correction or a problem found during delivery or monitoring.
Return the command's resulting record in plain language, including the new status, route when present, and next action.
Do not perform delivery, monitoring, closure, or new work merely because its lifecycle transition was recorded.
