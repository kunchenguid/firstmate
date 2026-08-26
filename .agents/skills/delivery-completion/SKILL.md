---
name: delivery-completion
description: Load before handling a ready PR, landing or cleaning up a task, completing a scout, or promoting scout work.
user-invocable: false
metadata:
  internal: true
---

# Delivery completion

## PR ready, landing, and cleanup

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/fm-pr-check.sh <id> <PR url>`; it records `pr=` and the forge's `pr_head=` when available and arms merge monitoring.
Tell the captain the full `https://...` PR URL, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine authority.
For a custom `state/<id>.check.sh`, use an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, and register its current bytes with `bin/fm-check-register.sh <id>` before execution.
A finite check prints a final wake line at terminal state and is retired on that wake with `bin/fm-check-register.sh retire <id>`.

Clean up a ship task only after landing is confirmed.
A refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force cleanup without explicit discard authority.
After successful cleanup, record completion, retain only configured recent Done history, and re-evaluate queued work whose blockers and time gates cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree or reader scratch directory can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `decision-hold-lifecycle`; cleanup enforces that shared completion gate.
When implementation is separately authorized, promote an existing writer scout through `bin/fm-promote.sh` rather than creating a duplicate task.
`bin/fm-promote.sh` refuses a reader scout, whose implementation dispatches as a fresh ship task.
The promoted worker inventories scratch state, returns to a clean default-branch base, carries over only intended fix changes, creates the ship branch, follows the selected delivery path, leaves scratch commits and debug edits behind, and turns a reproduced bug into the regression test.
