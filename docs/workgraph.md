# WorkGraph Slice 2

Slice 2 adds persistent parallelism modes and a non-enforcing one-node WorkGraph.
The tracked [`parallelism`](../schemas/workgraph/parallelism-v1.json), [`graph`](../schemas/workgraph/workgraph-v1.json), and [`slice contract`](../schemas/workgraph/slice-contract-v1.json) schemas are the exact machine-readable shape owners.
This document is the operator-facing contract and points to the executable owners.

## Parallelism modes

[`bin/fm-parallelism.sh`](../bin/fm-parallelism.sh) owns mode parsing, persistence, precedence, and status presentation.
The [`parallelism-v1` schema](../schemas/workgraph/parallelism-v1.json) owns the canonical persisted values.
`auto` is accepted only in command-line mode positions and is persisted and reported as `on`.
`FM_PARALLELISM_OVERRIDE` and persisted files accept canonical values only, so `auto` is invalid in either location.
An absent configuration resolves to `on` as a documented non-enforcing default.
Reading or inspecting that default never creates a configuration file.
An explicit selector-free `set on` or `set auto` command writes the canonical global `on` value.
The command never starts, stops, signals, steers, reclassifies, or rewrites an active task.
Run `bin/fm-parallelism.sh --help` for the exact commands and selectors.

Resolution precedence is request override, goal configuration, project configuration, and global configuration.
The request override may be supplied as `--request MODE` or `FM_PARALLELISM_OVERRIDE`.
An explicit command-line request wins when both request forms are present.
Status reports selected lower scopes as `uninspected` while a request override shadows them.
Goal selectors use the `goal_id` grammar owned by the [`workgraph-v1` schema](../schemas/workgraph/workgraph-v1.json).
Malformed persisted files, unsafe identifiers, and unknown modes fail closed.

[`configuration.md`](configuration.md#workgraph-storage-and-parallelism) owns the global, project, and goal storage locations.
The command header owns its atomic publication mechanic.
Parallelism mode is separate from the existing project delivery `mode=` vocabulary.

## One-node graph

[`bin/fm-workgraph.sh`](../bin/fm-workgraph.sh) owns Slice-2 graph and contract validation and status presentation.
The [`workgraph-v1`](../schemas/workgraph/workgraph-v1.json) and [`slice-contract-v1`](../schemas/workgraph/slice-contract-v1.json) schemas own all required fields, nested object shapes, identifiers, paths, enumerations, and numeric limits.
Slice 2 accepts the schemas' one-node graph form and an independently stored contract within the graph directory.
The validator captures its bytes once and hashes and parses that same captured sequence.
Run `bin/fm-workgraph.sh --help` for the exact validation and status commands.

`status` validates first and then reports the goal, one-node count, contract path, exact digest, and `enforcement=disabled`.
Duplicate JSON keys, recursively unknown object fields, more than one node, missing fields, unknown schema versions, unsafe identifiers, malformed claims, and bad contract hashes are errors.

Slice 2 intentionally does not normalize resources, compute waves, check compatibility, acquire or release leases, record gates, create snapshots, integrate output, or enforce dispatch decisions.
Existing brief and spawn behavior remains authoritative and does not consume these standalone configuration or graph files.

## Legacy opaque-endpoint compatibility gate

The governing Slice-2 contract requires a read-only migration prerequisite before any later local activation, fast-forward, canonical integration, or migration.
Pre-target active Herdr, Zellij, Orca, and cmux metadata without `endpoint_task_id` remains opaque and must not be rewritten, inferred, grandfathered, or bypassed with `--force`.
This standalone implementation does not activate WorkGraph behavior and does not change lifecycle code, active metadata, or supervising-home configuration.
