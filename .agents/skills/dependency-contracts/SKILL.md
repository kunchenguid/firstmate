---
name: dependency-contracts
description: >-
  Agent-only procedure for planning, recording, changing, clearing, and reconciling blocked-by edges.
  Use before any dependency mutation, before briefing work that blocks another task, before dispatching dependency-bound work, and when the selected dependency owner and backlog disagree.
user-invocable: false
metadata:
  internal: true
---

# Dependency contracts

Map every dependency edge to the exact capability that the dependent task consumes.
Do this before recording, changing, or clearing an edge, not after the blocker stalls.

## Evidence

Read blocker and dependent acceptance criteria, relevant issue discussion, existing reports, current repository behavior, and backlog records.
Do not infer hard dependency from preferred order, overlapping files, or broad issue titles.

Select one authoritative owner for the product dependency contract: a project issue or spec when either exists; only when neither exists may the backlog task body own it.
When an issue or spec owns the contract, the backlog mirrors task identity and the scheduling edge with a concise pointer; otherwise the backlog body states the contract.
The task brief is an execution snapshot, not a second authority.

## Edge contract

Record one contract per blocker and dependent pair:

- blocker and dependent identifiers
- type: `hard`, `contract`, or `soft`
- minimum capability dependent consumes
- executable proof capability works
- earliest safe spawn base: exact default-branch ref a fresh `fm-spawn.sh` will reset the dependent worktree to
- blocker scope dependent does not require
- release task and lifecycle owner whose owner-specific completion clears edge

Minimum capability belongs to edge, not blocker issue generally.
One blocker may expose different slices to different dependents.
If capability or proof cannot be stated, investigate before marking dependent ready.

Classify edge by whether a production-safe minimum capability can land before full blocker:

- `contract`: named independently shippable capability can unblock dependent before whole blocker completes
- `hard`: no independently safe slice exists, so full blocker completion is required
- `soft`: order reduces churn but independent progress remains safe

Only hard and contract edges become `blocked-by` backlog edges.
Keep soft ordering in task note or priority rather than hiding ready work.

## Unblocking slices

For a `contract` edge, create a dedicated ship task for its minimum capability.
Point dependent `blocked-by` edge at slice task, not whole issue task.
Keep original issue open until every remaining acceptance criterion lands.
Partial PR references issue without closing it.

Unblocking slice must be production-safe, independently reviewable, and executable with its proof from earliest safe spawn base.
Resolve that base from current `fm-spawn.sh` contract instead of assuming delivery target and spawn base are same.
For PR-backed modes, capability reaches spawn base only after landing on remote default branch.
For `local-only`, confirm local landing is visible in exact spawn base.
If it is not, keep edge blocked and escalate delivery-path mismatch rather than stacking branches or dispatching stale work.
An unmerged branch never clears edge.

For a `hard` edge, target full blocker task and state why no independently safe slice exists.
Never weaken trust-boundary validation, data safety, security, accessibility, or accepted product behavior to manufacture smaller slice.

## Backlog mutation

Use the configured backlog backend under `AGENTS.md` section 10; when it selects `tasks-axi`, use current help for exact commands.
Create the blocker task before the dependent task when recording an edge.
Preserve full structured dependency identifiers in backlog metadata; in the dependent task body, preserve the full contract when the backlog owns it or the concise pointer when an issue or spec owns it.

Choose the release task's normal owner-specific completion path when recording the edge.
A ship release task becomes complete for dependency purposes only after:

1. the task lands through its configured delivery path and the capability is present in the exact fresh dependent spawn base
2. the executable proof passes against that base
3. the consumed contract matches the selected authoritative owner

After all ship checks pass, run normal guarded `bin/fm-teardown.sh` for the release task.
A teardown refusal leaves the ship task and edge active.
Only successful teardown's configured-backend reminder may record ship-task completion.

A non-ship release task becomes complete for dependency purposes only after:

1. its selected lifecycle owner durably completes it
2. that owner's durable result satisfies the consumed contract
3. the executable proof passes against the exact fresh dependent spawn base and matches the selected authoritative owner

For a captain-held task whose answer is the release deliverable, `captain-hold-lifecycle`'s recorded answer and closed task are the authoritative durable completion proof.
A hold, status transfer, or recorded answer that releases the task to resume work does not complete it.
Follow the non-ship owner's normal completion mechanics rather than imposing ship landing or ship teardown.

After the selected completion path succeeds, re-evaluate readiness and dispatch newly ready items whose other gates cleared.
Do not use `tasks-axi unblock` to treat an unmerged commit, passing local branch, or partial validation as landed capability.

## Task brief handoff

Every task that blocks another task includes this task-specific section inside `{TASK}`:

```markdown
## Critical-path handoff

Dependents:
- <dependent issue or task>

Minimum unblocker:
- <exact capability>

Executable proof:
- `<command>` proves <observable result>

Stable contract:
- <API, event, payload, schema, or behavior that remainder must preserve>

Deferred remainder:
- <accepted blocker work not needed by listed dependent>
```

Worker implements and validates minimum unblocker first.
When remainder is independently shippable, brief only slice task and place remainder in separate task.

## Reconciliation

Before dispatching dependency-bound work, compare selected authoritative owner, backlog task state, edge targets, and landed artifacts.
A closed issue with unfinished acceptance work, open issue whose only task is done, missing edge contract, or edge targeting wrong whole-issue task is divergence.
Reconcile selected authoritative owner and backlog before dispatch.
Never close issue from unblocking-slice PR unless slice completes whole issue.

Completion: every active edge has one authoritative contract owner, exact consumed capability, executable proof, exact fresh spawn base, and one release task with owner-specific completion proof.
