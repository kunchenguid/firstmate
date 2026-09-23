---
name: reckon
description: >-
  Self-audit the session and fleet for missed or leftover work: traverse every task and decision this session touched, reconcile durable records against repo and PR reality, and report what is unfinished, unpushed, or silently diverged.
  Use when the captain invokes /reckon, asks "did we miss anything", "traverse all tasks and decisions", "what's left over", or for a completeness sweep before ending a work stretch.
user-invocable: true
metadata:
  internal: true
---

# reckon

A completeness audit, distinct from `bearings` (which reports what is in flight) and `stow` (which files knowledge).
Reckon answers: what did this session create, what finished, and what is left over or silently diverged.
It is read-only over fleet records and project checkouts; it never merges, pushes, tears down, or edits project files.

## Procedure

1. **Traverse the backlog.** `bin/fm-tasks-axi.sh list` — every task this session created or touched.
For each, confirm it reached a terminal state (done/closed) or name its live state.
A `done` row is not proof of landing: check its recorded artifact (PR URL merged? report file exists? branch landed?).
2. **Fold open decisions.** Run `bin/fm-wake-drain.sh` (or read its OPEN DECISIONS output if already drained this turn) and reconcile every entry: answered, superseded, or still owed to the captain.
Stale `blocked`/`needs-decision` lines superseded by later events are called out as superseded, not reported as open.
3. **Check merge state.** For every PR-based task, verify the PR actually merged (`gh pr view` or the task's `pr=` metadata plus merge poll record).
For local-only work, verify the branch landed in the target checkout.
4. **Check live checkouts vs clones vs origin.** For each project with a live checkout the captain works in (per `data/captain.md`), compare: clone vs origin, live vs origin, live vs clone.
Flag unpushed local commits, uncommitted WIP blocking merges, and changes merged to origin but not yet pulled into the live checkout.
5. **Check leftovers.** Untorn-down tasks, leaked worktrees, armed-but-dead check scripts, unacknowledged inbox notes, and config drift this session introduced (e.g. edited `config/` files, global tool configs like `~/.no-mistakes/config.yaml`).
6. **Report.** One compact list: closed items with their artifacts, then open items with the exact blocker or next step, then leftovers.
State plainly when nothing is missing; never pad the open list with non-issues.

## Rules

- Never discard uncommitted work found during the audit; report it.
- Never mutate project checkouts; reconciliation of dirty state is a separate captain-authorized action.
- The audit's own findings belong in the reply, not in durable records, unless the captain asks to file them.
