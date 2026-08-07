---
name: implement
metadata:
  internal: true
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

When running as Firstmate, commission one ship through the task lifecycle and put the specification or tickets plus the checks below in its brief.
When running as the delegated implementation worker, implement the described work in the assigned worktree.

Use /tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, use /code-review to review the work.

Deliver through the repository's configured lifecycle.
