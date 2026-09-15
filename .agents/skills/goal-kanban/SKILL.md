---
name: goal-kanban
description: >-
  Agent-only planning procedure for organizing ideas through Inbox, Refining, Ready, and Closed states,
  refining one card at a time, and modeling approved multi-part goal chains with explicit dependencies.
  Use when a Codex crewmate needs a planning queue or a chain contract, never for task execution.
metadata:
  internal: true
---

# goal-kanban

Use this skill to organize a crewmate's planning work as a small, auditable Kanban.
The Kanban is a reasoning model, not a server, database, scheduler, or orchestration system.
It does not create a Node board, spawn a process, poll a monitor, open a tunnel, dispatch a crewmate, create a worktree, execute a goal, create or merge a PR, or change project state.
Firstmate owns task records, dispatch, supervision, delivery, and merge authority.

## Board states

Represent the current board in the caller's existing brief or in a compact response table when no task record exists.
Do not create a new persistent board or invent a second source of truth.

- `Inbox`: the idea is captured but its outcome and boundary are not yet concrete.
- `Refining`: one card is active and the crewmate is asking one question at a time.
- `Ready`: the card has an auditable `/goal` or an approved chain contract and is ready for a separate Firstmate workflow.
- `Closed`: planning is complete or the caller archived the card, and this state never means that implementation finished.

A card should contain an id, title, raw idea, current state, and ordered question-and-answer history.
At `Ready`, it must also contain the selected scenario and either a rendered goal or a chain contract.
Keep the raw idea and answers intact enough for a reviewer to audit how the plan was formed.
Move one card at a time unless the caller explicitly asks for a different review order.

## Refinement loop

Load [`../goal-prompt-builder/SKILL.md`](../goal-prompt-builder/SKILL.md) before turning a card into a `/goal`.
That skill owns project-type detection, reusable formats, the five-section goal contract, and auditability scoring.

1. Capture the idea in `Inbox` without pretending that it is a specification.
2. Move the card to `Refining` when questions begin.
3. Ask the single next question whose answer changes the objective, scope, constraints, proof, or stop conditions.
4. Preserve each question and answer in the card history or caller-owned task record.
5. Render the goal only after the builder's auditability check passes.
6. Move the card to `Ready` and return the artifact to the caller.
7. Move the card to `Closed` only when the caller closes the planning record, never when implementation merely begins.

If the caller gives a direct, complete specification, infer answers already present and ask no redundant question.
If the caller requests execution, stop at `Ready` and hand the artifact back to the Firstmate-owned workflow.

## Folders and batches

Group ideas only when the caller confirms that they share one objective, one scope boundary, and one acceptance contract.
Keep each source idea visible in the grouped card as a numbered member rather than silently discarding it.
Use the builder's `batch` scenario when the group is a known enumerable set.
Split a group back into separate cards when its members need different constraints, proofs, or stop conditions.

## Chain contracts

Propose a chain when one idea contains independent deliverables, crosses distinct boundaries, or cannot fit into one auditable goal without dropping concrete proofs.
Do not split a task merely to make the board look busy.
Ask for explicit approval of the part titles and dependency graph before recording an approved chain.

An approved chain has one shared contract and ordered parts.
The shared contract contains the objective, scope, constraints, and a one-line map of the parts.
Each part contains a title, its `after` dependency list, and its own auditable `Done when` and `Stop if` sections.
Each part must be understandable without copying a neighboring part's full text.
Render each part as a complete `/goal` by combining the shared Objective, Scope, and Constraints with that part's proof and stop sections.
Keep the shared contract stored once and inject it only when presenting a part for review.

Use this abbreviated, non-Ready sketch to illustrate the planning shape.

```text
Chain: <shared objective and the ordered part map>

Contract:
  Objective: <after-state for the whole idea>
  Scope: <boundary shared by every part>
  Constraints:
    - <rule shared by every part>

Part 1: <title>
  After: none
  Done when:
    1. <concrete proof>
  Stop if:
    - <mechanically detectable condition>

Part 2: <title>
  After: 1
  Done when:
    1. <concrete proof>
  Stop if:
    - <mechanically detectable condition>
```

Use `After: none` for an explicit root and list every required predecessor for dependent parts.
If the chain has a final integration or closeout part, it must list every part that it consumes in `After`.
Do not imply a dependency from numbering alone.
Record parallelism only as a graph fact, without prescribing a worktree or a concurrent process.
Record cross-part file or ownership conflicts as stop conditions in the affected parts.

The chain reaches `Ready` only when the shared contract is complete and each fully rendered part passes the builder's auditability checks.
An approved chain does not authorize implementation, dispatch, merging, or delivery.

## Review output

For a board review, show the cards grouped by state and identify the one card currently in `Refining`.
For a ready card, show the rendered `/goal` or the shared contract plus ordered parts.
For a chain, show the dependency graph and name any unresolved approval or boundary question.
Do not report implementation status, PR status, branch status, or execution progress from this planning model.
