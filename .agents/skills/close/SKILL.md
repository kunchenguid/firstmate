---
name: close
description: >-
  Review or close completed Firstmate tasks so acknowledged work leaves /tasks and moves into durable private history.
  Use when the captain invokes /close, asks to close or archive completed work, or asks what should be retained before closing.
user-invocable: true
metadata:
  internal: true
---

# close

For `/close --review <selector>`, run `bin/fm-close.sh --review <selector>` and return its proposal without performing any mutation.
Inspect the named task's private report or instructions only when the captain asks what Firstmate recommends retaining.
Apply the knowledge-routing rules already owned by `AGENTS.md`: task-specific material stays in the closed-task archive, fleet facts go to `data/learnings.md`, preferences go to the appropriate captain record, project-wide knowledge requires the project's normal delivery path, and general Firstmate knowledge requires Firstmate's normal delivery path.

For routine `/close <selector>...`, run `bin/fm-close.sh <selector>...`.
The command independently verifies every task, composes guarded cleanup when needed, archives useful private material, removes only verified Done rows through the configured backlog owner, and leaves failed batch members current.
Report each concrete closure or refusal in plain language.

When the captain explicitly chooses and the destination has already been written through its normal owner, add `--retained <destination>` so the closure record links it.
When the captain explicitly authorizes follow-up work, create that task through `bin/fm-tasks-axi.sh` first and add `--follow-up <canonical-id>` to a single-task close.
Never create speculative follow-up work merely because review mode recommends considering it.

Stop for the specific captain decision when retention is genuinely ambiguous, cleanup would discard work, or follow-up work lacks authorization.
Do not use `--force` or delete task resources directly.
