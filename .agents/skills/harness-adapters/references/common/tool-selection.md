# Tool selection

This resource is the single owner of capability-based tool selection for primary, scout, ship, promoted-scout, and secondmate work.
If the current session is known to be OMP, read the [OMP reference](../harness/omp.md) before choosing or invoking tools.
Tool selection remains usable when the current harness identity is unknown, but it does not make an unknown harness eligible for dispatch or lifecycle operations.

## Selection order

1. Follow explicit task tool requirements and existing Firstmate operation owners first.
2. For ordinary agent work, choose an exposed native tool that supports the actual operation while preserving its required scope and semantics.
3. Inspect the active tool's current description and schema instead of inferring support from the model, an installed command-line client, the supervisor's harness, or shell-side harness detection.
4. When the operation is absent or its required semantics are unsupported, use the existing command-line path.
5. Name a consequential substitution, and request installation consent only when its required fallback is missing.
6. A denied operation, authentication failure, or uncertain write outcome is not permission to try another tool blindly.
7. Preserve the operation's existing authorization and error rules, and establish a write's outcome before attempting it again.

## Firstmate-owned operations

Tool selection never replaces Firstmate's lifecycle and durable-state owners.
Keep `fm-spawn`, `fm-send`, `fm-control`, the existing OMP supervision extension, `fm-pr-check`, `fm-pr-merge`, `fm-merge-local`, `fm-teardown`, `fm-tasks-axi`, and the selected no-mistakes path authoritative for their operations.
Native task agents, Eval `agent()`, `orchestrate`, and `hub` do not replace Firstmate fleet lifecycle.
Native `todo` plans only the current session and is not the durable backlog.
A native `ask` answer that settles a tracked captain call still follows `captain-hold-lifecycle`; native questions do not create or resolve durable decisions automatically.
