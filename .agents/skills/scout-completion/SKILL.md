---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before relaying a scout report to the captain, run `plain-check` on `data/<id>/report.md` when the tool is on PATH.
On exit 1 while the scout is still live, steer the scout once to fix its report; otherwise relay anyway and say in one line that the report did not pass the plain-writing check.
The check never blocks a relay beyond that one steer and never judges facts.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
