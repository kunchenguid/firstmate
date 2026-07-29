# WorkGraph Slice 2

Slice 2 adds persistent parallelism modes and a non-enforcing one-node WorkGraph.
The tracked schemas under [`schemas/workgraph/`](../schemas/workgraph/) are the machine-readable shape owner.
This document is the operator-facing contract and points to the executable owners.

## Parallelism modes

[`bin/fm-parallelism.sh`](../bin/fm-parallelism.sh) owns mode parsing, persistence, precedence, and status presentation.
The canonical modes are `off`, `eco`, `on`, and `max`.
`auto` is accepted as an input alias and is persisted and reported as `on`.
Persisted files accept canonical modes only, so a manually stored `auto` value is invalid.
An absent configuration resolves to `on` as a documented non-enforcing default.
Reading or inspecting that default never creates a configuration file.
An explicit selector-free `set on` or `set auto` command writes the canonical global `on` value.
The command never starts, stops, signals, steers, reclassifies, or rewrites an active task.

Use the simple forms below.

```sh
bin/fm-parallelism.sh get
bin/fm-parallelism.sh set eco
bin/fm-parallelism.sh status
```

Optional selectors are available for reads and scoped writes.

```sh
bin/fm-parallelism.sh get --request max
bin/fm-parallelism.sh get --goal goal-1 --project project-1
bin/fm-parallelism.sh set off --project project-1
bin/fm-parallelism.sh set auto --goal goal-1
```

Resolution precedence is request override, goal configuration, project configuration, and global configuration.
The request override may be supplied as `--request MODE` or `FM_PARALLELISM_OVERRIDE`.
Status reports selected lower scopes as `uninspected` while a request override shadows them.
The goal and project selectors use safe identifiers containing 1 to 64 ASCII letters, digits, dots, underscores, or hyphens.
Malformed persisted files, unsafe identifiers, and unknown modes fail closed.

[`configuration.md`](configuration.md#workgraph-storage-and-parallelism) owns the global, project, and goal storage locations.
Each write creates a temporary file in the target directory and publishes it with an atomic same-directory rename.
Parallelism mode is separate from the existing project delivery `mode=` vocabulary.

## One-node graph

[`bin/fm-workgraph.sh`](../bin/fm-workgraph.sh) owns Slice-2 graph and contract validation and status presentation.
The graph is a JSON object with `schema_version` `workgraph/v1`, a safe `goal_id`, and exactly one `slices` reference.
The reference contains a safe `slice_id`, a safe relative `contract_path`, and a lowercase `contract_sha256` digest.
Contract paths reject traversal, empty segments, and Unicode control characters.
The referenced contract is an independently stored JSON file below the graph directory.
The validator captures its bytes once and hashes and parses that same captured sequence.

The contract uses schema version `slice-contract/v1` and repeats matching `slice_id` and `goal_id` values.
Its required fields are `purpose`, `type`, `depends_on`, `immutable_inputs`, `outputs`, `claims`, `worktree`, `harness`, `model`, `effort`, `acceptance`, `validation_commands`, `expected_evidence`, `context_budget`, `gates`, `implementer`, `independent_validators`, and `authorized_exceptions`.
Every output is a non-empty path string.
The allowed slice types are `ship`, `scout`, `audit`, and `integration`.
Each immutable input has a `path` and a lowercase SHA-256 `sha256` digest.
Each claim has a `resource` and one of `read`, `write`, or `exclusive`.
The one-node contract has an empty `depends_on` array.
The context budget contains positive `source_tokens` and `report_words` integers.

Validate or inspect a graph with these commands.

```sh
bin/fm-workgraph.sh validate path/to/goal.json
bin/fm-workgraph.sh status path/to/goal.json
```

`status` validates first and then reports the goal, one-node count, contract path, exact digest, and `enforcement=disabled`.
Duplicate JSON keys, recursively unknown object fields, more than one node, missing fields, unknown schema versions, unsafe identifiers, malformed claims, and bad contract hashes are errors.

Slice 2 intentionally does not normalize resources, compute waves, check compatibility, acquire or release leases, record gates, create snapshots, integrate output, or enforce dispatch decisions.
No lifecycle script is changed by this slice, so existing brief and spawn behavior remains authoritative.

## Legacy opaque-endpoint compatibility gate

The governing Slice-2 contract requires a read-only migration prerequisite before any later local activation, fast-forward, canonical integration, or migration.
Pre-target active Herdr, Zellij, Orca, and cmux metadata without `endpoint_task_id` remains opaque and must not be rewritten, inferred, grandfathered, or bypassed with `--force`.
This standalone implementation does not activate WorkGraph behavior and does not change lifecycle code, active metadata, or supervising-home configuration.
