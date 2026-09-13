# Fleet

How several concurrently active FirstMate managers share the work without becoming each other's bottleneck.

```text
                         User
                          │
                 thin fleet control
                          │
       ┌──────────────────┼──────────────────┐
       │                  │                  │
    FirstMate A        FirstMate B        FirstMate C
       │                  │                  │
   SecondMates        SecondMates        SecondMates
       │                  │                  │
    Crewmates           Crewmates           Crewmates
```

## Invariants

Multiple FirstMates may run concurrently.
Each physical FirstMate uses its own `FM_HOME`.
One live authority exists per `FM_HOME`.
One FirstMate owns each SecondMate at a time.
One durable owner exists per outcome.
Fleet control is thin and owns no solution reasoning.
Routine work never flows through a global Primary.
SecondMates autonomously manage their domain execution.
Crewmate completion is not parent completion.
Independent review remains independent.
Cross-shard coordination uses durable state.
Loss or model-wait of one manager never serializes other shards.
AutoDev is a temporary migration backstop, not a duplicate orchestration authority.

## Concepts

A manager is one physical FirstMate process holding one `FM_HOME` lease.
A shard is that manager's bounded portfolio: its scope, SecondMates, projects, and domains.
The fleet root holds `fleet.json`, the control-plane source of truth for manager registration, ownership, and cross-shard dependencies.
The fleet root performs no reasoning and relays no routine messages.
Each manager supervises 2–4 active SecondMates initially, which is an operating range rather than a product limit.
A fleet with one manager is the supported degenerate case and behaves like today's single FirstMate home.

## Authority

Exactly one authoritative FirstMate owns a given SecondMate at a time.
Registration and every start refuse a SecondMate that already belongs to another manager.
Starting a second live authority for the same manager ID, `FM_HOME`, or lease fails safely.
A manager start also refuses when that home's session lock is held by a live FirstMate session.
The per-home session lock in `bin/fm-lock.sh` still owns one-authority-per-home; the fleet lease in `<home>/state/.fleet-lease` extends the same rule to manager processes.
Concurrent managers never share one mutable `FM_HOME`.
Fleet commands serialize registry writes through a lock directory and validate before mutating.

## CLI

All commands need `--fleet-root <dir>` or `FM_FLEET_ROOT`, and fail closed without it.
`fm-fleet.sh init` creates an empty registry.
`fm-fleet.sh register` adds or updates one manager shard with an absolute home, a scope, and SecondMate, project, and domain lists.
`fm-fleet.sh validate` checks duplicate IDs, homes, SecondMates, projects, and domains, plus overlapping homes, before anything mutates.
`fm-fleet.sh start` validates first, pre-checks every shard for a live authority, then launches one manager process per shard.
`fm-fleet.sh status` prints the compact manager table described below.
`fm-fleet.sh attach <id>` prints read-only inspection commands and the stop-then-shell takeover path, including the Mac mini over SSH.
`fm-fleet.sh restart <id>` stops and starts one manager inside its own durable home.
`fm-fleet.sh stop <id>` or `stop --all` terminates processes while shards stay registered.
`fm-fleet.sh route` resolves new work to exactly one manager by SecondMate, then project, then domain.
`fm-fleet.sh progress`, `set-wait`, and `set-blocked` record a shard's signals.
Progress markers merge into the next heartbeat, so status observes them within one heartbeat interval.
The manager daemon is the single writer of its heartbeat file.
`fm-fleet.sh dep add | list | done` records durable cross-shard dependencies.

## Status

`fm-fleet.sh status` answers which managers are alive, what each owns, which shard is blocked, who waits on a model, and who stopped progressing.
States are `running`, `model-wait`, `idle`, `blocked`, `stalled`, `stopped`, and `dead`.
Waiting on a provider is healthy and never counts as stalled.
`stalled` means no meaningful progress inside `FM_FLEET_STALL_SECS` without a wait or block.
`stopped` means a clean stop with the shard still registered; `dead` means the process is gone without one.
Status never reports completion, because completion belongs to each shard's Definition-of-Done and landing evidence.

## Routing

Every new project or task resolves to one FirstMate owner through explicit mappings.
SecondMate ownership wins over project mapping, which wins over domain mapping.
Overlapping project or domain mappings fail validation so routing stays deterministic.
Correct ownership matters more than optimal distribution, so no automatic rebalancing exists.

## Cross-shard dependencies

A task that needs another shard records one owning FirstMate plus a durable dependency on the other shard.
Ownership never transfers through a dependency and joint ownership never exists.
The owner's status shows `blocked` with the needed shard and task until `dep done` closes it.
Routine progress needs no global relay.

## Failures

A crashed manager stays listed with its SecondMates, and no other manager acquires its shard implicitly.
Restart recovers the same home, heartbeat, progress, and registry entries rather than building a duplicate tree.
Provider exhaustion in one shard leaves the others running with their durable state intact.
If fleet control itself is unavailable, running managers keep supervising from their own homes.

## Backends

Managers run under tmux when it is present and under `nohup` otherwise.
`FM_FLEET_BACKEND=tmux` or `=nohup` pins the choice.
Both backends run real processes; tmux additionally survives the launching shell.
`FM_FLEET_BACKEND=herdr` runs each manager as one tab per manager inside one `fm-fleet` workspace in the resolved Herdr session, so managers stay visible on the operator's normal Herdr surface.
The Herdr backend reuses the verified tab-create, submit, and kill primitives from `bin/backends/herdr.sh`; tabs are labeled `fleet-<id>` and never collide with task tabs.
Explicit selection stays required for Herdr because it is experimental and session-dependent.

## Migration

The current single FirstMate becomes the first fleet shard with its existing home.
AutoDev and Paperclip remain available as a reversible backstop while equivalence is proven.
Required AutoDev invariants move into the canonical FirstMate path as documented in `fleet-autodev-convergence.md`.
Redundant orchestration is disabled only after migration evidence exists, and dead paths are removed last.

## Pilot sharding

Partition by project and domain topology so cross-manager dependencies stay rare.
Keep each manager's SecondMates in related domains and leave a manager empty rather than fabricating ownership.
Static ownership comes first; load data later decides whether two or four SecondMates per manager is the better range.
