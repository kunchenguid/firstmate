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
The fleet root and every manager home live on durable storage (for example `~/.fm-fleet`), never in `/tmp`, because restart recovery depends on leases, heartbeats, and progress surviving process death.
The fleet root performs no reasoning and relays no routine messages.
Each manager supervises 2–4 active SecondMates initially, which is an operating range rather than a product limit.
A fleet with one manager is the supported degenerate case and behaves like today's single FirstMate home.

## Authority

Exactly one authoritative FirstMate owns a given SecondMate at a time.
Registration and every start refuse a SecondMate that already belongs to another manager.
Starting a second live authority for the same manager ID, `FM_HOME`, or lease fails safely.
A manager start also refuses when that home's session lock is held by a live FirstMate session.
The per-home session lock in `bin/fm-lock.sh` still owns one-authority-per-home; the fleet lease in `<home>/state/.fleet-lease` extends the same rule to manager processes.
Concurrent managers never share one mutable `FM_HOME`. Home paths are stable storage locators and are never renamed; human identity lives in the registry id, so a rename touches the registry and the Herdr labels but never moves a home directory.
Fleet commands serialize registry writes through a lock directory and validate before mutating.

## CLI

All commands need `--fleet-root <dir>` or `FM_FLEET_ROOT`, and fail closed without it.
`fm-fleet.sh init` creates an empty registry.
`fm-fleet.sh register` adds or updates one manager shard with an absolute home, a scope, and SecondMate, project, and domain lists.
`fm-fleet.sh validate` checks duplicate IDs, homes, SecondMates, projects, and domains, plus overlapping homes, before anything mutates.
`fm-fleet.sh start` validates first, pre-checks every shard for a live authority, then launches one manager process per shard.
`fm-fleet.sh status` prints the compact manager table described below.
`fm-fleet.sh attach <id>` prints read-only inspection commands, the live Herdr tab target with a peek command, and the stop-then-shell takeover path, including the Mac mini over SSH.
`fm-fleet.sh restart <id>` stops and starts one manager inside its own durable home.
`fm-fleet.sh stop <id>` or `stop --all` terminates processes while shards stay registered.
`fm-fleet.sh route` resolves new work to exactly one manager by SecondMate, then project, then domain.
`fm-fleet.sh progress`, `set-wait`, and `set-blocked` record a shard's signals.
Progress markers merge into the next heartbeat, so status observes them within one heartbeat interval.
The manager daemon is the single writer of its heartbeat file.
`fm-fleet.sh dep add | list | done` records durable cross-shard dependencies.

## Status

`fm-fleet.sh status` answers which managers are alive, what each owns, which shard is blocked, who waits on a model, and who stopped progressing.
States are `running`, `model-wait`, `idle`, `blocked`, `stalled`, `ready`, `stopped`, and `dead`.
`ready` means registered but never started; a manager may wait in `ready` rather than having ownership fabricated for it.
Waiting on a provider is healthy and never counts as stalled.
`stalled` means no meaningful progress inside `FM_FLEET_STALL_SECS` without a wait or block.
`stopped` means a clean stop with the shard still registered; `dead` means the process is gone without one.
Status never reports completion, because completion belongs to each shard's Definition-of-Done and landing evidence.

## Routing

Every new project or task resolves to one FirstMate owner through explicit mappings.
SecondMate ownership wins over project mapping, which wins over domain mapping; projects are the primary durable key and domains only the fallback for cross-cutting work.
Overlapping project or domain mappings fail validation so routing stays deterministic.
An empty table fails closed (`no manager owns ...`) rather than guessing; unassigned work returns to the operator.
Correct ownership matters more than optimal distribution, so no automatic rebalancing exists.

## Questions

Anyone with a question for the fleet asks through `fm-fleet.sh ask <id> <text>` for one manager or `ask --all <text>` for every manager.
Delivery is a thin primitive: the text is submitted to the manager's Herdr tab and the manager answers in its pane from its own shard.
A question spanning shards goes to `--all`; each manager answers for its shard and the asker synthesizes the answers.
Synthesis stays with the asker, never with a global reasoner, so broadcast never becomes joint ownership or a backdoor Primary.

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

A manager home has two live forms, never both at once.
The placeholder form is the supervised heartbeat daemon (`bin/fm-fleet-manager.sh`): it holds the fleet lease, publishes heartbeats, and exits cleanly on SIGTERM.
It runs under tmux when tmux is present and under `nohup` otherwise; `FM_FLEET_BACKEND=tmux` or `=nohup` pins the choice.
The reasoning form is a real FirstMate session (Codex) running in the home with `FM_HOME` set, holding the home session lock.
`FM_FLEET_BACKEND=herdr` runs each manager in its own workspace per manager home (label `firstmate-<id>`, so the side panel reads `firstmate-runtime` and friends) with one tab per manager (label `fleet-<id>`) in the resolved Herdr session, so managers stay visible on the operator's normal Herdr surface with live agent states, matching the workspace-per-home rule SecondMates and Crewmates follow.
The Herdr backend reuses the verified tab-create, submit, and kill primitives from `bin/backends/herdr.sh`; tabs are labeled `fleet-<id>` and never collide with task tabs.
Explicit selection stays required for Herdr because it is experimental and session-dependent.
A reasoning session takes a home only after that home's daemon is stopped (`fm-fleet.sh stop <id>`); `fm-fleet.sh start` refuses a home whose session lock is held by a live session, and the daemon refuses to start there too.
`fm-fleet.sh status` shows `agent` in DETAIL while a reasoning session holds the home and the daemon form otherwise, so the operator can always tell which form is live.

## Migration

The current single FirstMate becomes the first fleet shard with its existing home.
AutoDev and Paperclip remain available as a reversible backstop while equivalence is proven.
Required AutoDev invariants move into the canonical FirstMate path as documented in `fleet-autodev-convergence.md`.
Redundant orchestration is disabled only after migration evidence exists, and dead paths are removed last.

## Pilot sharding

Partition by project and domain topology so cross-manager dependencies stay rare.
Keep each manager's SecondMates in related domains and leave a manager empty rather than fabricating ownership.
Static ownership comes first; load data later decides whether two or four SecondMates per manager is the better range.
