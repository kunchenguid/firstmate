---
name: implement-spec
description: >-
  Orchestrate implementation of a spec or plan with multiple tasks as a dependency graph.
  Use when the captain provides a spec, feature design, or implementation plan that decomposes into multiple concurrent tasks.
  Adapted from Matt Pocock's implement-spec skill for firstmate's orchestration model.
user-invocable: false
metadata:
  internal: true
---

# implement-spec

Orchestrate a multi-task implementation from a spec or plan.
Load when the captain provides a spec to implement, or when a research/plan phase produces an implementation plan with multiple tasks that have blocking relationships.

## When to use

A single-task ship does not need this skill.
Load it when the deliverable decomposes into two or more tasks with a dependency graph between them.
The spec may come from the captain directly, from a scout report, or from the research/plan phase of the compaction workflow.

## Workflow

### 1. Read the spec and build the task graph

Read the spec.
Identify every discrete task and its blocking relationships.
The result is a directed graph, not a list.
At any point there is a **frontier**: the set of tasks whose blockers are all resolved.

Record the graph in the backlog.
Each task is a `tasks-axi` item with `--blocked-by` edges.
The spec itself is the context pointer every worker receives.

### 2. Optional: dispatch a scout for exploration

When the spec touches unfamiliar code, APIs, or external systems, dispatch one scout first.
The scout compacts its findings into `data/<id>/report.md`.
Workers receive a pointer to that report, not duplicated text.
Skip this when the spec already carries enough codebase context.

### 3. Create the integration branch

Before dispatching workers, decide the integration strategy:
- **Single PR per task** (default for independent changes): each worker opens its own PR.
- **Shared target branch** (for tightly coupled tasks): create one branch and one draft PR; each worker merges into it via its own sub-branch.

Use the single-PR path unless the tasks produce changes that must ship atomically.

### 4. Dispatch frontier workers in parallel

For every task on the current frontier, dispatch a ship worker.
Each worker gets:
- A brief pointing to the spec (path, not copy).
- A pointer to the scout report if one exists.
- Its own worktree via treehouse.
- The vertical-slices instruction: stub end-to-end first, then add logic per slice.

Workers run concurrently.
Do not wait for one to finish before dispatching another whose blockers are clear.
Respect the dependency graph: a task whose blocker is unresolved stays queued.

### 5. Advance the frontier as workers complete

When a worker reports done:
- Verify its PR or branch.
- Check whether its completion unblocks other tasks in the graph.
- Dispatch newly unblocked tasks immediately.
- Repeat until the graph is fully resolved.

### 6. Integration and review

When all tasks are done:
- For single-PR flows: each PR merges independently.
- For shared-branch flows: review the combined diff on the integration branch.
- Run the project's configured checks before marking anything ready.

### 7. Clean up

Tear down completed workers only after landing is confirmed.
Release worktrees back to the pool.

## Communication contract

Workers communicate through files, not chat duplication.
The spec, the scout report, and each worker's status file are the shared context.
Firstmate steers workers through their durable inbox; a worker never reads another worker's pane.

## Context discipline

The spec file is the single source of truth for what is being built.
The scout report is the single source of truth for codebase understanding.
Each worker's brief contains only pointers to these, plus task-specific acceptance criteria.
Do not copy spec content into briefs.
