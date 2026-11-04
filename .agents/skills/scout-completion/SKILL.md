---
name: scout-completion
description: Load when an Investigator reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Investigator outcome and promotion

A completed Investigator must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When an Investigator's deliverable is a visual artifact the user will iterate on, keep it alive and follow the worker-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from the Director.
When implementation is separately authorized, promote the existing Investigator through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the Builder branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
