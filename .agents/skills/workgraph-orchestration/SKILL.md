---
name: workgraph-orchestration
description: >-
  Agent-only owner for turning sliced Firstmate work into sealed WorkGraphs and safely
  admitting compatible slices through claims, leases, gates, evidence, snapshots, and serial integration.
  Load for every new software intake after feature-slicing, including a one-slice task.
user-invocable: false
metadata:
  internal: true
---

# workgraph-orchestration

Load this after `feature-slicing` for every new software intake.
This skill owns orchestration after decomposition; `feature-slicing` remains the owner of how a broad goal becomes small reviewable slices.
Represent a small task as a one-node WorkGraph and a larger task as a bounded DAG.

## Durable contract

Store the graph, one sealed contract per slice, the resource registry, gate records, evidence, and snapshots below `data/`.
Treat their exact bytes and SHA-256 digests as authoritative.
Store leases durably through the WorkGraph authority; runtime projections, admission locks, heartbeats, and caches below `state/` are disposable.
Use `bin/fm-workgraph-migrate.sh rebuild-state <graph>` to recreate the derived projection.

Every slice contract declares its identity, goal, purpose, type, dependencies, immutable inputs and digests, outputs, resource claims, worktree, harness/model/effort, acceptance, validation commands, expected evidence, context budget, gates, implementer, independent validators, and authorized exceptions.
Use one exclusive worktree and branch or detached head per slice.
Use distinct output paths and runtime namespaces.
An integration slice must name `Firstmate` as implementer and exclusively claim `lock://FIRSTMATE-INTEGRATION`.
An audit slice has read claims only and consumes an immutable snapshot.

## Compatibility and modes

The graph and declared claims are the source of truth; never maintain an independent pairwise compatibility matrix.
Two slices may overlap only after dependencies and predecessor gates pass and every intersecting resource is read/read.
Any write/read, write/write, or exclusive intersection conflicts.
Parent/child paths, shared worktrees, overlapping outputs, branches, Docker resources, ports, services, databases, UI sessions, and locks are resources, not informal scheduling notes.
An absent, malformed, unregistered, or ambiguous resource fails closed at the broadest applicable container.
Legacy active tasks without a complete lease-backed WorkGraph binding are broadly exclusive.

Resolve the mode in request, goal, project, then global order.
`off` admits one task.
`eco` admits at most two compatible slices and does not commission speculative work.
`on` is the normal adaptive mode and admits the compatible work whose parallel execution has reasonable benefit.
`max` admits the full compatible wave and may commission redundant investigation or validation to reduce wall time.
`auto` is a command-line alias for `on`; persist only `on`.
A mode change applies to future admissions and never signals, rewrites, or terminates active work.

## Dispatch

1. Seal immutable inputs and record every SHA-256.
2. Validate the graph and strict resource registry with `bin/fm-workgraph.sh`.
3. Inspect `bin/fm-workgraph-migrate.sh status`; stop on an invalid binding and treat every reported legacy task as exclusive.
4. Derive deterministic waves and inspect conflicts with `ready`, `waves`, and `explain-conflict`.
5. Generate the task brief with `bin/fm-brief.sh --workgraph <graph> --slice <slice>`.
6. Spawn with the same graph and slice plus `--registry <registry>`.
7. Confirm task metadata records the graph, contract and registry hashes, wave,
   endpoint lease ID, fencing token, holder PID, and holder start ticks.

`fm-spawn.sh` serializes only admission, revalidates the sealed bytes and
worktree, applies mode capacity, and compares every active sealed contract
across goal boundaries before rejecting incompatible or legacy overlap.
It first holds a provisional lease with its live launcher PID, then—under the
same dispatch lock and before agent launch—releases it and acquires a superior
fenced lease bound to the persistent runtime endpoint shell PID and start
ticks. A missing or unstable endpoint identity fails closed.
Do not bypass a refusal or infer an undeclared resource.
Locks are never reassigned because a TTL elapsed; recover only after positive holder-death evidence and a superior fencing token.

## Gates, evidence, and completion

Record gate results only from an independent validator declared by the contract.
Freeze raw evidence before interpretation and bind it by SHA-256.
Do not open downstream admission until every transitive predecessor gate is currently passed with intact evidence.
Use a clean content-addressed Git snapshot for every audit.
Firstmate alone may integrate or publish canonical bytes, and integration remains serial under its exclusive lock.

Completion requires every gate on the selected contract to pass with intact evidence.
`fm-teardown.sh` preserves WorkGraph work while gates, evidence, integration, or the held lease are incomplete, even with `--force`.
After safe cleanup it releases the exact lease terminally before removing task metadata.
Authorized exceptions remain narrow, attributed, and expiring; they do not silently bypass claims, gates, leases, or completion.
