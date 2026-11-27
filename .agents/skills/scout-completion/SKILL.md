---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation, and when any worker report lists numbered follow-ups.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it, and the same holds for its follow-ups.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-dispatch.sh promote` (operator contract: `docs/configuration.md` "Typed dispatch resolution") rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.

## Follow-up intake

Workers list only follow-ups that absolutely must be done, as numbered items in the done report only.
When closing a ship or scout, firstmate reads that list once, before teardown, and decides for each item whether to start a new task now under the usual authority or discard it.
Never record the list or its dispositions separately, or defer an item to a suggestions backlog.
Surface urgent security or data-loss findings promptly and use `captain-hold-lifecycle` for decisions that actually require the captain.
