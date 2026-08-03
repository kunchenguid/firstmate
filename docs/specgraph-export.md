# SpecGraph snapshot export

This document is the stable Phase 1 collection contract for systems such as GBrain.
It defines only private snapshot production and pickup, with no query layer, rollback behavior, network call, scheduler, or GBrain-internal dependency.

## Boundary

```text
existing durable write point
            |
            v
best-effort local capture
            |
            v
$FM_HOME/data/specgraph/*.json
            |
            v
external collector reads new sequence numbers
```

The producer writes snapshots under `$FM_HOME/data/specgraph/` for the active firstmate home.
The directory and every snapshot are private local data under gitignored `data/` and must never be committed.
The writer applies directory mode `0700` and file mode `0600`.
Collection is read-only and must not modify `.sequence`, `.capture.lock`, snapshot files, or the firstmate home.

## File and cursor contract

Snapshot names use `<12-digit-sequence>-<capturedAt-UTC>-<event>-<subject>-<idempotency-prefix>.json`.
An example is `000000000042-20260803T120000Z-task-completed-cp23-f83a3f81a6b2.json`.
The leading sequence is the canonical incremental cursor and is monotonically increasing within one home.
`capturedAt` is the producer observation time, while `effectiveAt` is the semantic effective time when known.
Consumers must order by `sequence`, retain the highest successfully ingested value per home, and collect files whose `sequence` is greater than that cursor.
Consumers may use `capturedAt` for time filtering but must not use it as a uniqueness key.
The full `trigger.idempotencyKey` is the event identity, and a repeated identical capture returns the existing file instead of allocating another sequence.

## Schema contract

Every file sets `schemaVersion` to `specgraph.snapshot.v0.1`.
The canonical machine-readable shape is [`specgraph-snapshot-v0.1.schema.json`](specgraph-snapshot-v0.1.schema.json).
The producer can validate a collected file with `bin/fm-specgraph-capture.sh validate <snapshot.json>`.
The `Snapshot` node is first-class and mirrors the top-level `baselineId`, `parent`, `effectiveAt`, `capturedAt`, set hashes, `authorityCompleteness`, and `status` fields.
Set hashes use canonical compact key-sorted JSON, and `nodeSetSha256` excludes `Snapshot` lineage nodes to avoid a self-referential hash.

The node vocabulary is `Goal`, `Decision`, `Spec`, `Component`, `WorkflowMap`, `Task`, `Artifact`, `Evidence`, `Assumption`, `Claim`, `ReviewAssertion`, `Capability`, `Gate`, `Gap`, and `Snapshot`.
The core path remains `Goal -> Decision -> Spec -> Component/WorkflowMap -> Task/Artifact -> Evidence`.
The additional edges cover assumption support, claim evidence, review adoption, capability gates, gaps, snapshot lineage, and node validity.
Every `supersedes` edge must carry a non-empty scope plus `supersession.mode` of `full` or `partial`.

Actor identity stays metadata in v0.1.
Its fields distinguish `human`, `model`, or `unknown`; harness, model, effort, role, authority, and independence remain nullable or explicitly unknown when no filed source establishes them.

## Evidence and incompleteness

Every node and edge carries `epistemic.level` as `CONFIRMED`, `INFERRED`, or `UNKNOWN` and at least one `sourceRef`.
`CONFIRMED` is valid only with `CAPTAIN` or `FILED_EVIDENCE` authority.
An inference remains `INFERRED` even when a supporting file is present, until an explicit captain decision or filed evidence confirms the exact semantic claim.
The producer never promotes an inferred record during capture or validation.

Snapshots from event hooks are drafts and may be `INCOMPLETE` because one write point rarely establishes the active Goal, Spec, WorkflowMap, or complete baseline.
Missing, unreadable, or unsafe source material produces an `UNKNOWN` record and a concrete `incompleteReasons` entry.
The producer must not silently skip the event or invent a node to make the record look complete.
`authorityCompleteness` independently reports `COMPLETE`, `PARTIAL`, or `UNKNOWN`.

## Capture points and failure behavior

The producer attaches only to existing durable write points for task teardown, resolved decision files, task-local `captain-decision*.md` framework corrections, and exact merged-PR receipts.
Capture does not alter the success, refusal, or supervision semantics of those owners.
A capture failure leaves the primary flow successful and appends a private line to `state/specgraph-capture.failures.log` when that state directory is writable.
The failure log is operational evidence of a missing snapshot and is not itself a replacement snapshot.

Phase 1 performs no network access and does not contact GBrain.
Scheduling and downstream ingestion are outside this repository's producer contract.
