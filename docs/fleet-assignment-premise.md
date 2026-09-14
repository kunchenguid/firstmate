# Fleet Assignment Premise

## Observed Current State

This section is a 2026-09-13 runtime snapshot and is not a test fixture or durable source of truth.

The existing fleet registry stores projects, domains, and SecondMates inside physical manager rows.
That makes an operational process identity such as `runtime` appear to be the durable semantic owner.
The live primary FirstMate registry instead shows that `harness` is the persistent SecondMate for the `AutoDev` and `dotcodex` projects.
The Harness SecondMate has its own durable home at `/Users/cheng_huang/.treehouse/firstmate-7bab20/1/firstmate`.
Four separate Codex processes currently hold four isolated fleet homes, but none supervises a SecondMate.

## Intended Behavior

Canonical semantic ownership is:

```text
project or domain -> SecondMate
```

Operational supervision is:

```text
SecondMate -> exactly one active FirstMate manager
```

Physical FirstMate identities represent interchangeable capacity.
They do not encode project or domain taxonomy.
The normal intake path resolves a project or domain to one SecondMate, keeps a healthy sticky manager assignment, or atomically selects the least-loaded healthy manager.
Unknown semantic ownership enters a durable unassigned triage record.
It does not silently guess, create a duplicate SecondMate, or ask the captain to select a physical manager.

## Authority And State

`fleet.json` is the thin control-plane source of truth for manager registration, exclusive semantic owner registrations, active manager assignments, unassigned intake, and cross-SecondMate dependencies.
The `projects:` field in `data/secondmates.md` remains the existing non-exclusive clone list and is not used as the exclusive intake key.
Fleet registry mutation remains serialized by the existing fleet lock, and every mutation validates and writes by temporary file plus atomic rename while still holding that lock.
Each assignment records the SecondMate, manager, assignment generation, state, assignment time, and latest recovery reason.
Exactly one active assignment may exist for a SecondMate.
The assignment stays sticky while its manager is healthy.
Manager death leaves the assignment and SecondMate known.
Recovery deliberately replaces the assignment generation only after the prior manager is proven dead or stopped.
No manager may acquire a SecondMate whose current manager can still be alive.
Recovery moves the authoritative supervision binding into the selected live manager through the journaled transfer transaction before it publishes the new generation.

The SecondMate's persistent home, project registry, backlog, and completion evidence remain the semantic execution state.
The manager registry does not clone or move that home.
An assignment record carries no done, reviewed, landed, acceptance, or root-completion field.

The authoritative supervision binding is the SecondMate home's `.fm-secondmate-parent` record together with exactly one parent home's `data/secondmates.md` route and `state/<id>.meta` endpoint record.
A manager is assignable only when its isolated home session lock is held by a live reasoning harness; a heartbeat-only daemon is capacity-ready but cannot supervise a SecondMate.
Model-wait remains a healthy assignable state.

Supervision transfer is a journaled fail-closed transaction in registry schema version 2.
It first validates and snapshots the source binding, registry row, task metadata, status channel, and destination state.
It refuses when the existing pending-reply library finds any record for that SecondMate whose phase is not `resolved`, including escalated or recovery-unknown records.
Resolved pending-reply records remain untouched in the source home; any journal reference to them is informational and rollback does not move or delete them.
It then proves the source supervisor and selected destination manager are stopped, stops and relaunches the SecondMate endpoint so no launch-time parent environment survives, records a preparing transaction, removes the source parent route and metadata, rewrites `.fm-secondmate-parent`, installs the destination route and metadata, atomically publishes the new assignment generation, and restarts the destination manager and SecondMate under the new parent home.
The source and destination sessions remain stopped during the owner-record rewrite, so no supervisor can act on a partial move.
A crash before assignment publication leaves the transaction recoverable and the SecondMate unassigned rather than jointly supervised.
Recovery refuses while either relevant `fm-lock.sh status` reports a live holder.
The original FirstMate therefore stops supervising `harness` before the fleet publishes a replacement assignment.
The selected manager becomes the only parent authority for the relaunched Harness SecondMate endpoint.

## Operator Surface

Operational manager IDs are `manager-1` through `manager-4`; the four existing durable homes are retained and relabeled in place.
The Herdr adapter maps those IDs to workspaces `FirstMate 1` through `FirstMate 4` and tabs `Manager 1` through `Manager 4` rather than deriving raw `firstmate-manager-*` labels.
Fleet status shows manager health, active SecondMate count, assigned SecondMate names, wait or blocked state, and last progress.
It also shows semantic owner registrations and unassigned triage separately.

The operator submits work by project, domain, issue, or known SecondMate.
The fleet returns and, for intake, records this complete route:

```text
project/domain -> SecondMate -> current FirstMate manager
```

## Acceptance Checks

1. A version 1 registry migrates without losing manager homes, process state, or dependency records.
   A manager row with one SecondMate can lift its project and domain mappings into that SecondMate's owner registration and sticky assignment only when that SecondMate's durable parent binding names the manager home.
   Ambiguous legacy mappings become unassigned triage records, and ambiguous open manager-keyed dependencies remain explicit legacy dependencies until resolved.
2. Project and domain uniqueness is validated across SecondMate owner registrations.
3. A SecondMate has at most one active manager assignment.
4. Existing healthy assignments remain sticky.
5. A new SecondMate is assigned atomically to the least-loaded healthy reasoning manager, with manager ID as the deterministic tie breaker.
   Load is the number of active SecondMate assignments, not the heartbeat's task count.
6. A live reasoning manager or model-wait reasoning manager is eligible and is not classified as stalled solely because it waits on a provider.
7. A dead manager does not affect other managers and its SecondMate remains assigned until deliberate recovery.
8. Recovery rejects a reasoning manager while its `FM_HOME` session lock has a live holder, then replaces the assignment generation after the manager is stopped or proven dead through the existing session-lock liveness check.
9. Duplicate manager ID, home, live home authority, SecondMate owner, and SecondMate assignment are rejected.
10. Unknown project or domain intake creates one idempotent unassigned triage record and no fabricated SecondMate.
11. Cross-shard dependencies name SecondMates as semantic owners and do not create joint manager ownership.
    Ambiguous version 1 manager dependencies are retained as labeled legacy records rather than guessed.
12. A child or Crewmate completion cannot complete a SecondMate or root outcome without the existing DoD and independent review evidence.
13. One manager can wait or die while the other three continue to accept prompts and record progress.
14. The existing single-manager case remains valid.
15. Harness remains the semantic owner of AutoDev and dotcodex while its supervision migrates atomically from the original FirstMate to one selected fleet manager.
16. A different healthy manager can recover Harness after controlled termination without the captain selecting the replacement.
17. A new AutoDev issue resolves to Harness and its current manager without physical-manager input.
18. Transfer refuses while the SecondMate has an open pending reply, and a successful transfer relaunches the SecondMate so its process environment names only the destination parent.

## Changed Surfaces

`docs/fleet.md`, `docs/fleet-autodev-convergence.md`, `bin/fm-fleet.sh`, `bin/fm-fleet-manager.sh`, `bin/fm-fleet-herdr.sh`, the SecondMate provisioning routing contract, and `tests/fm-fleet.test.sh` move together to schema version 2.
The version 2 migrator is explicit and idempotent.
Manager health is collected before assignment locking, and the selected reasoning-session lock is revalidated inside the short registry transaction so a four-manager health scan never holds the fleet lock beyond its waiter budget.
Status may run one bounded session-lock probe per manager outside the fleet lock; it must not add a per-SecondMate subprocess scan.

## Rollback

AutoDev and Paperclip remain available during the pilot.
Before Harness supervision moves, preserve the original SecondMate parent binding, registry route, endpoint metadata, status channel, and assignment generation in the transaction journal.
Resolved pending-reply records remain in the original source home and open records block the move.
Rollback refuses while the fleet manager session remains live, restores `.fm-secondmate-parent`, the original registry route and parent-side records, clears only the matching assignment generation, and relaunches the same Harness SecondMate from the original FirstMate home.
No SecondMate home, backlog, project checkout, worktree, or completion evidence is copied or deleted during migration.
