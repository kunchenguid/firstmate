---
name: dependency-contracts
description: >-
  Agent-only procedure for planning, recording, changing, clearing, and reconciling blocked-by edges.
  Use before any dependency mutation, before briefing work that blocks another task, and when issue and backlog dependency records disagree.
user-invocable: false
metadata:
  internal: true
---

# Dependency contracts

Map every dependency edge to exact capability that dependent task consumes.
Do this before recording or changing edge, not after blocker stalls.

## Evidence

Read blocker and dependent acceptance criteria, relevant issue discussion, existing reports, current repository behavior, and backlog records.
Do not infer hard dependency from preferred order, overlapping files, or broad issue titles.

When project has issue or spec, that surface owns product dependency contract.
Backlog mirrors task identity and scheduling edge, with concise pointer to owner.
For work without project issue, backlog task body owns contract.
Task brief is execution snapshot, not second authority.

## Edge contract

Record one contract per blocker and dependent pair:

- blocker and dependent identifiers
- type: `hard`, `contract`, or `soft`
- minimum capability dependent consumes
- executable proof capability works
- earliest safe base: merged slice or completed blocker
- blocker scope dependent does not require
- unblocking task whose completion clears edge

Minimum capability belongs to edge, not blocker issue generally.
One blocker may expose different slices to different dependents.
If capability or proof cannot be stated, investigate before marking dependent ready.

Classify edge:

- `hard`: dependent cannot compile, run, migrate, or validate without landed capability
- `contract`: dependent can proceed once stable API, event, payload, schema, or error behavior lands
- `soft`: order reduces churn but independent progress remains safe

Only hard and contract edges become `blocked-by` backlog edges.
Keep soft ordering in task note or priority rather than hiding ready work.

## Unblocking slices

When minimum capability can ship independently, create dedicated ship task for it.
Point dependent `blocked-by` edge at slice task, not whole issue task.
Keep original issue open until every remaining acceptance criterion lands.
Partial PR references issue without closing it.

Unblocking slice must be production-safe, independently reviewable, and executable from merged default branch.
Current Firstmate spawns fresh workers from remote default branch, so an unmerged branch does not clear edge.
Do not invent stacked-branch machinery.

If full blocker really is minimum safe capability, keep one task and state that evidence explicitly.
Never weaken trust-boundary validation, data safety, security, accessibility, or accepted product behavior to manufacture smaller slice.

## Backlog mutation

Use current `tasks-axi` help for exact commands.
Create blocker task before dependent task when recording edge.
Preserve contract pointer in dependent task body and full structured dependency identifiers in backlog metadata.

Clear edge only after:

1. unblocking task landed through configured delivery path
2. executable proof passes against landed head
3. consumed contract matches dependent issue

Then mark slice task done, run `tasks-axi ready`, and dispatch every newly ready item whose other gates cleared.
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

Before dispatching dependency-bound work, compare project issue state, backlog task state, edge targets, and landed artifacts.
A closed issue with unfinished acceptance work, open issue whose only task is done, missing edge contract, or edge targeting wrong whole-issue task is divergence.
Reconcile authoritative issue and backlog before dispatch.
Never close issue from unblocking-slice PR unless slice completes whole issue.

Completion: every active edge has one owner, exact consumed capability, executable landed proof, and one task whose completion releases dependent work.
