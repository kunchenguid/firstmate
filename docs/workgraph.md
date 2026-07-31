# WorkGraph

WorkGraph is Firstmate's persistent contract for slicing work, deriving safe parallelism from declarative resource claims, and enforcing admission through gates and fenced leases.
The tracked [`parallelism`](../schemas/workgraph/parallelism-v1.json), [`graph`](../schemas/workgraph/workgraph-v1.json), [`slice contract`](../schemas/workgraph/slice-contract-v1.json), [`resource registry`](../schemas/workgraph/resource-registry-v1.json), gate, evidence, exception, and snapshot schemas are the exact machine-readable shape owners.
The migration inventory and state-rebuild command results are owned by [`migration-status-v1`](../schemas/workgraph/migration-status-v1.json) and [`state-rebuild-result-v1`](../schemas/workgraph/state-rebuild-result-v1.json).
This document owns the current operator contract, while [`workgraph-orchestration`](../.agents/skills/workgraph-orchestration/SKILL.md) owns the agent procedure.

## Parallelism modes

[`bin/fm-parallelism.sh`](../bin/fm-parallelism.sh) owns mode parsing, persistence, precedence, and status presentation.
The [`parallelism-v1` schema](../schemas/workgraph/parallelism-v1.json) owns the canonical persisted values.
`auto` is accepted only in command-line mode positions and is persisted and reported as `on`.
`FM_PARALLELISM_OVERRIDE` and persisted files accept canonical values only, so `auto` is invalid in either location.
An absent configuration resolves to the normal adaptive `on` default.
Reading or inspecting that default never creates a configuration file.
An explicit selector-free `set on` or `set auto` command writes the canonical global `on` value.
The command never starts, stops, signals, steers, reclassifies, or rewrites an active task.
Run `bin/fm-parallelism.sh --help` for the exact commands and selectors.

`off` admits one task, `eco` admits at most two compatible slices without speculative dispatch, `on` admits compatible work with reasonable parallel benefit, and `max` admits the full compatible wave and permits redundant investigation or validation.
The mode affects only new admissions.
`fm-parallelism.sh status` ends with `enforcement=disabled` because the resolver does not itself launch or block work; `fm-spawn.sh` is the contract-bound enforcement point that consumes the resolved mode.

Resolution precedence is request override, goal configuration, project configuration, and global configuration.
The request override may be supplied as `--request MODE` or `FM_PARALLELISM_OVERRIDE`.
An explicit command-line request wins when both request forms are present.
Status reports selected lower scopes as `uninspected` while a request override shadows them.
Goal selectors use the `goal_id` grammar owned by the [`workgraph-v1` schema](../schemas/workgraph/workgraph-v1.json).
Malformed persisted files, unsafe identifiers, and unknown modes fail closed.

[`configuration.md`](configuration.md#workgraph-storage-and-parallelism) owns the global, project, and goal storage locations.
The command header owns its atomic publication mechanic.
Parallelism mode is separate from the existing project delivery `mode=` vocabulary.

## Graphs and contracts

[`bin/fm-workgraph.sh`](../bin/fm-workgraph.sh) owns graph and contract validation, compatibility projections, leases, gates, evidence, and snapshots.
The [`workgraph-v1`](../schemas/workgraph/workgraph-v1.json) and [`slice-contract-v1`](../schemas/workgraph/slice-contract-v1.json) schemas own all required fields, nested object shapes, identifiers, paths, enumerations, and numeric limits.
Every intake has a graph: one bounded task uses one node and larger work uses a bounded DAG of independently acceptable slices.
Each graph reference binds an independently stored contract within the graph directory by SHA-256.
The validator captures its bytes once and hashes and parses that same captured sequence.
Run `bin/fm-workgraph.sh --help` for the exact validation and status commands.

`status` validates first and then reports the goal, nodes, exact contract digests, resource projection, mode, deterministic waves, durable lease status, and gate status when gate records exist.
Its historical `enforcement=disabled` field identifies the static projection boundary; it does not mean contract-bound dispatch is advisory.
Duplicate JSON keys, recursively unknown object fields, missing fields, unknown schema versions, unsafe identifiers, malformed claims, cycles, and bad contract hashes are errors.

## Bounded DAG and static compatibility

`workgraph/v1.slices` accepts 1..256 references.
Each bound contract may declare up to 255 dependencies, 64 claims, and 64 outputs.
Dependencies come only from the bound contracts and are checked for missing, self, duplicate, and cyclic edges in graph order.
Exact duplicate canonical worktrees and unsafe or overlapping outputs within one contract fail closed.
Parent/child worktrees and cross-slice output overlap remain valid graph inputs but produce compatibility reasons.
Audit slices are read-only.
Integration slices require the `Firstmate` implementer and exactly one exclusive `lock://FIRSTMATE-INTEGRATION` claim.

`waves <graph> [--registry FILE] [--mode off|eco|on|max|auto]` and `ready` use only normalized claims, explicit registry bytes, worktrees, outputs, and dependency closure.
`auto` is the read-only alias for `on`; without an explicit mode the existing goal/global resolver is read once.
`explain-conflict` emits deterministically sorted dependency, worktree, output, and resource reasons.
Only overlapping `read/read` resources are compatible.
Wave capacities are 1 for `off`, 2 for `eco`, and unbounded for `on` and `max`.
`ready` separately counts dependency-, compatibility-, and capacity-blocked nodes.
Static commands end with `enforcement=disabled`; hard errors emit no partial output, and bound spawn separately enforces their sealed result.

## Durable leases and fencing

`bin/fm-workgraph.sh acquire`, `release`, `recover`, `fence`, and `inspect` provide the durable lease authority.

Lease authority state is stored below `FM_DATA_OVERRIDE` or `FM_HOME/data` in `workgraphs/.leases/v1`, with immutable revision records, monotonic fencing tokens, transaction ownership, and append-only event files.

Recovery requires positive process-identity evidence such as an absent PID, an identity mismatch, or a changed boot identifier.

Recovery records use `state=recovered`, `terminal.kind=recover`, and a nonempty terminal actor; the recover event has no actor field and binds the exact committed revision-2 record digest.

The authority validates the canonical data boundary without changing its existing mode, while lease-owned descendants are created and retained as mode 0700 and authority files as mode 0600.

## Resource identifiers and normalization

[`bin/fm-workgraph.sh`](../bin/fm-workgraph.sh) owns the `normalize`, `lint`, and `registry` commands. Normalization is a pure local operation: it performs no DNS, daemon, Docker, Git, or network lookup and uses ASCII grammar checks, locale-independent string operations, and POSIX path operations only.

Supported forms are `path://`, absolute POSIX `worktree://`, `branch://`, `docker://project`, `docker://network`, `docker://volume`, `docker://container`, `port://host/port`, `svc://service/account`, `db://instance/schema`, `ui://profile/session`, and `lock://name`. Named worktree identifiers are rejected. Docker kinds may have an optional lowercase instance segment. Branch refs use slash-separated named components and the Git-forbidden forms are rejected.

`path:///absolute` and `worktree:///absolute` are POSIX forms. They reject backslashes, repeated separators, control characters, percent/query/fragment encodings, traversal above `/`, inputs over 4096 UTF-8 bytes, and more than 1024 structural segments. `.` and `..` are resolved lexically, then the longest existing prefix is passed to `realpath`; a regular file is valid as the terminal component, while a file or other non-directory prefix followed by a suffix is `WG-R-FS`. Any non-existent suffix is appended lexically and is never created. Dangling links, loops, permission failures, and `ENOTDIR` before the terminal component are `WG-R-FS`. Tilde expansion, environment expansion, DNS aliases, and case folding of case-sensitive path, branch, and instance segments are deliberately not performed.

Authorities and namespaces are ASCII and case-stable; service, database, and UI authorities are canonicalized lowercase. Port hosts accept lowercase RFC-1123 DNS names, canonical IPv4 literals, and bracketed RFC 5952 IPv6 output; IPv4 leading zeroes and IPv6 zone identifiers are rejected. Port numbers are decimal integers in the inclusive range 1..65535 and are emitted without leading zeroes. Unknown namespaces and malformed resources are never coerced into another namespace.

## Advisory claim linting

`fm-workgraph.sh lint claims.json [--registry registry.json]` accepts exactly a claims array, the strict `resource-claims/v1` object, or a complete graph whose contracts pass full validation.
`status` accepts the same optional explicit registry pair.
It prints deterministic per-claim projections, including `canonical_id_json` and fail-closed effective mode or scope, plus indexed warning records.
An explicit invalid registry is a hard error; no registry is discovered or created.

`status` performs the same claim projection over every validated contract and always ends its static portion with `enforcement=disabled`.
It reports `resource_lint=pass` when there are no warnings and `resource_lint=warn` otherwise.
Malformed, unknown, unregistered, and ambiguous claims always use `effective_mode=exclusive`; malformed or unknown claims use global scope, while unregistered claims use exactly one intrinsic root as `container:<safe-id>`, global for zero roots, and `ambiguous` or global for multiple roots.
Standalone lint never mutates runtime state.
Bound dispatch separately requires an explicit valid registry and acquires the fail-closed projected resources through the lease authority.

## Strict resource registry

[`resource-registry-v1`](../schemas/workgraph/resource-registry-v1.json) is the strict owner for `{ "schema_version": "resource-registry/v1", "instances": [...] }`. Each instance has a safe WorkGraph `id`, closed `namespace`, canonical `resource`, `aliases`, and instance-ID `contains` edges. Runtime validation rejects duplicate IDs/resources/aliases, non-canonical resources, cross-namespace aliases, undefined or duplicate references, self-links, multiple parents, and cycles. `fm-workgraph.sh registry registry.json` validates the exact regular-file input without acquiring or observing the represented resource.

## Legacy opaque-endpoint compatibility gate

`bin/fm-workgraph-migrate.sh status` is the read-only migration prerequisite for inspecting active metadata before dispatch or activation.
It classifies a complete graph, contract, registry, and held-lease binding as `workgraph`, metadata with no WorkGraph fields as `legacy-exclusive`, and every partial, ambiguous, changed, duplicate-worktree, or otherwise unverifiable binding as `invalid`.
It never rewrites active task metadata and exits nonzero when an invalid binding exists.
Pre-target active Herdr, Zellij, Orca, and cmux metadata remains opaque and must not be rewritten, inferred, grandfathered, or bypassed with `--force`.
`fm-spawn.sh` preserves those bytes and treats every legacy active record as broadly exclusive when deciding a new dispatch.

## Disposable runtime projection

`bin/fm-workgraph-migrate.sh rebuild-state <graph>` recreates `state/workgraphs/<goal-id>/projection.txt` atomically from validated graph bytes, persisted mode configuration, and durable gate and lease records.
The projection reports the exact static WorkGraph status and resolved parallelism status but is never canonical evidence.
Deleting it changes no durable authority; rebuilding the same state from the same inputs produces the same bytes and SHA-256.
The command refuses symlinked or non-ordinary state targets.

## Contract-bound brief and dispatch enforcement

WorkGraph enforcement applies only to explicitly bound new dispatches.
`fm-brief.sh <task> <project> --workgraph <graph> --slice <slice>` validates the complete graph, selects one contract, stores those exact contract bytes as `data/<task>/slice-contract.json` with mode `0600`, and renders purpose, dependencies, claims, acceptance, validation, evidence, budgets, gates, and implementer or validator identities into the ordinary ship or scout brief.
The task ID must equal the slice ID.
`ship|integration` contracts generate ship briefs; `scout|audit` contracts generate scout briefs.

`fm-spawn.sh` requires the same graph and slice plus an explicit strict resource registry.
It reselects the contract and compares it byte-for-byte with the brief snapshot before acquiring a provisional lease or creating a runtime backend.
The declared worktree must already exist, be its Git top level, belong to the selected project's Git common directory, and differ from the primary checkout.
The contract's harness, model, effort and task kind are enforced exactly.

One short `state/.workgraph-dispatch.lock` serializes admission through metadata publication.
It never serializes the agents after launch.
Admission checks the resolved `off|eco|on|max` capacity, validates every active WorkGraph metadata record against its sealed graph and registry hashes plus a held lease, compares the candidate contract with every active contract, rejects overlapping worktrees, outputs, or non-`read/read` resources even when their `goal_id` values differ, and then acquires the candidate's claims through the fenced lease authority.
Compatible `read/read` leases may coexist.
Any active task with missing, ambiguous, non-regular, or invalid WorkGraph metadata is treated as legacy and therefore broadly exclusive.
A new legacy task is also exclusive while any other task metadata exists.
The single `id=repo` compatibility spelling remains available, but a multi-task legacy batch rejects before its first spawn; compatible parallel work launches as individually bound slices.

The launcher process owns a short provisional lease while the selected session
provider creates an empty endpoint. While the same dispatch lock remains held,
Firstmate proves that endpoint's persistent shell PID twice, terminally releases
the provisional lease, and acquires a new lease with a superior fencing token
bound to that shell's PID and start ticks. The agent is not launched until this
handoff succeeds. A provider without a verifiable persistent endpoint identity,
or a failed endpoint acquisition, closes the empty endpoint and fails closed.
This avoids detached guardian processes that a supervisor can reap when
`fm-spawn.sh` exits, and it never reassigns a lock because time elapsed.

Successful metadata records the goal, slice, static wave, graph, contract and
registry digests, endpoint lease ID, fencing token, holder PID, and holder start
ticks.
A failed spawn releases a lease it acquired; successful task teardown owns terminal release.
Orca is rejected for a contract-bound dispatch because Orca allocates its own worktree instead of entering the predeclared one.

## Gates, evidence, snapshots, and protected completion

The gate authority stores every gate observation as an immutable numbered revision.
A gate record binds goal, slice, exact gate string, selected contract digest, independent validator, pass or fail state, and one content-addressed evidence digest.
Repeating the same observation is byte-idempotent; a changed result or evidence creates the next revision.
The latest revision is authoritative, and a contract-byte change makes every prior result stale.

`record-gate` accepts only actors named by the selected contract's `independent_validators`.
Evidence must be a single-link regular file, is captured without following symlinks, and is stored by SHA-256 before the gate record becomes visible.
`record-evidence` provides the same content-addressed store for validation, output and audit artifacts.
Unknown files, broken sequences, changed digests, unsafe paths, and torn records fail closed.

`gate-check` blocks a slice until every gate of every transitive dependency is currently passed, and refuses redispatch when the selected slice is already complete.
`completion-check` requires all gates declared by the selected contract to be currently passed with intact evidence.
Explicit WorkGraph spawn calls `gate-check` before admission.
`fm-teardown.sh` calls `completion-check` before any destructive cleanup and verifies the exact held lease.
Even `--force` cannot bypass that WorkGraph completion boundary.
Teardown terminally releases the lease only after endpoint and worktree cleanup and before removing task metadata.

`snapshot` accepts only a clean declared Git worktree and publishes the exact `git archive --format=tar HEAD` bytes under their digest with a manifest binding commit, tree, contract, actor, size and SHA-256.
Repeating the same tree is byte-identical.
Contract `immutable_inputs` are re-opened without following symlinks and rehashed before dispatch, so audit slices can consume snapshots without receiving write claims.
Integration slices remain serialized by the exclusive `lock://FIRSTMATE-INTEGRATION` lease.

The tracked schemas `gate-result-v1.json`, `evidence-result-v1.json`, `snapshot-manifest-v1.json`, and `exception-record-v1.json` own these durable record shapes.
Exceptions are declarative, narrow, attributed and expiring.
No exception is interpreted as permission to bypass gates, leases, or teardown safety.
