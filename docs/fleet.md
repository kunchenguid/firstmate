# Fleet

The fleet runs interchangeable FirstMate reasoning managers without making a physical process the semantic owner of a project or domain.

```text
project or domain -> SecondMate -> active FirstMate manager
```

## Authority

`fleet.json` schema version 2 is the thin control-plane source of truth.
Manager rows contain only an ID and an isolated `FM_HOME`.
Exclusive owner rows map projects and domains to persistent SecondMates.
Assignment rows map each SecondMate to at most one active manager and carry a monotonically increasing generation.
Unassigned intake, SecondMate-keyed dependencies, legacy dependencies, and transfer state are separate collections.

The `projects:` field in `data/secondmates.md` remains the non-exclusive clone list.
It is not the fleet's exclusive intake key.
The SecondMate home remains the source of truth for its backlog, project registry, lifecycle evidence, and Definition of Done.
Fleet assignment state has no completion, review, landing, or acceptance field.

Every registry mutation holds a kernel `flock` on `<fleet-root>/.fleet.lock`, which the operating system releases when a holder crashes, validates the full document, writes a temporary file in the same directory, calls `fsync`, and publishes it with `rename`.
Manager health is collected before assignment locking.
The selected home session lock is checked again before the short assignment mutation.

## Managers

Operational manager IDs are `manager-1` through `manager-4`.
Their Herdr workspaces are labeled `FirstMate 1` through `FirstMate 4`, and their tabs are labeled `Manager 1` through `Manager 4`.
The home path stays stable when the human label changes.

`FM_FLEET_BACKEND=herdr fm-fleet.sh start` launches the configured interactive harness in each manager home and waits for the live home session lock.
The default interactive manager harness is Codex; `FM_FLEET_MANAGER_HARNESS` may select another verified harness accepted by `bin/fm-fleet-herdr.sh`.
The tmux and nohup backends run only the heartbeat daemon.
That daemon is `capacity-ready` and cannot receive a SecondMate assignment because it does not hold a reasoning-session lock.

`stop` closes a fleet-created Herdr tab and waits for its reasoning lock to clear.
It refuses to kill a live reasoning session that has no recorded fleet Herdr target.
`restart` uses the same guarded stop and start sequence.

## Registry Commands

All commands require `--fleet-root <dir>` or `FM_FLEET_ROOT`.

```sh
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" init
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" manager register \
  --id manager-1 --home "$HOME/.fm-fleet/homes/manager-1"
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" owner register \
  --secondmate harness --home "$HARNESS_HOME" \
  --projects AutoDev,dotcodex --domains harness
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" validate
```

Registration is idempotent for an exact row and refuses conflicting reuse of an ID, home, project, domain, or SecondMate.

## Assignment And Intake

`assign --secondmate <id>` keeps a healthy existing assignment sticky.
For an unassigned SecondMate it chooses the healthy reasoning manager with the fewest active SecondMate assignments, with manager ID as the tie breaker.
`model-wait` is healthy and assignable.
A heartbeat daemon, stopped manager, dead manager, stalled manager, blocked manager, or manager without a live home lock is not an assignment candidate.

A dead manager does not erase or move its assignments.
`recover --secondmate <id>` proves the current manager no longer has a live reasoning lock, selects the least-loaded healthy peer, and runs a failover supervision transfer into that live manager.
The failover moves `.fm-secondmate-parent`, the parent route, and the endpoint records before it publishes the next generation, so the assignment never names a manager that the owner records do not back.
A SecondMate without a valid source binding and route cannot be recovered.

`route` accepts a known SecondMate, project, domain, issue, or combination and prints the complete route.

```text
--project AutoDev --issue MIX-900 -> harness -> manager-1 (generation 3)
```

Unknown or disagreeing semantic keys create one idempotent unassigned record.
Repeated intake increments that record's attempt count and never fabricates a SecondMate or asks the operator to choose a physical manager.

## Status

`status` shows each manager's state, active assignment count, assigned SecondMate names, dependency block, and progress detail.
It then shows semantic owners and unassigned triage separately.
`status --json` returns `managers`, `owners`, and `unassigned` arrays.
Status runs at most one bounded session-lock probe per manager and does not spawn a process per SecondMate.

States are `running`, `model-wait`, `idle`, `blocked`, `capacity-ready`, `ready`, `stopped`, and `dead`.
Provider wait does not become stalled merely because the model is waiting.
Status never reports task or root completion.

## Dependencies

Dependencies name the owning and needed SecondMates.
They do not assign a manager or create joint ownership.

```sh
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" dep add \
  --owner harness --from MIX-900 --needs paperclip --task PC-42
```

Version-1 manager-keyed dependencies migrate only when both manager-to-SecondMate mappings are unique and binding-confirmed.
Ambiguous records remain in `legacy_dependencies` with their original structured record.

## Version-1 Migration

`migrate` is explicit and idempotent.
It preserves manager home paths and relabels sorted legacy rows as `manager-1`, `manager-2`, and so on.
A legacy row lifts its project and domain keys only when it names exactly one SecondMate, that SecondMate has exactly one route in the manager home's `data/secondmates.md`, and `.fm-secondmate-parent` names the same manager home.
Every ambiguous key becomes unassigned triage instead of being guessed.

```sh
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" migrate
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" validate
```

## Supervision Transfer

Transfer is a local, journaled parent-authority move.
It validates the owner, assignment generation, source route, source metadata and status, destination absence, and SecondMate parent binding.
Any pending-reply record whose phase is not `resolved` blocks the move.
Resolved records stay in the source home and are not deleted or copied.

The source home session lock must be stopped before `transfer begin`.
`--to` is optional. Without it, one fleet-lock critical section selects the least-loaded healthy reasoning manager, excluding the source and any manager reserved by an unfinished transfer journal, and writes the `preparing` journal.
That journal validates every non-liveness precondition above and reserves the destination, so two concurrent transfers cannot select or stop the same manager.
Only then does the command stop the selected destination and recheck both endpoint locks.
The command prints the transaction id before it stops anything.
One exit trap is armed from the reservation until the transfer is active. It runs on every failure, including a fleet-lock timeout or a signal.
Under the fleet lock, the trap checks the registry for a claim row for this transaction. The record claim takes the same lock, and a claim refuses a journal that is no longer `preparing`.
If no claim row exists, the trap marks the journal `abandoned`, restarts a destination that this command stopped, and relaunches a stopped source SecondMate. The assignment and parent records stay unchanged.
If the claim has committed, the trap restarts nothing. It leaves the journal and the stopped endpoints for `transfer recover` or `transfer rollback`, and prints that hint.
If the fleet lock stays busy, the trap also restarts nothing. It prints `transfer abandon --transaction <id>`, which retries the same conditional release.
The journal records `destination_stopped` and `secondmate_stopped`, so the trap and `transfer abandon` restart the same endpoints.
The registry transaction row is the only source of mutation authority.
Each SecondMate has one current transfer. A record claim removes every older transfer row for that SecondMate, and the journals keep the audit history.
`transfer recover` and `transfer rollback` require their transaction to be that SecondMate's only row, in the `records-ready`, `published` or `active` state. They check this before running any endpoint hook. So an unclaimed stale journal, or an older active transaction that a newer claim superseded, is refused even when the generations match.
`transfer abandon` refuses a claimed or finished transaction.
A journal is audit and recovery evidence, and it never grants endpoint authority by itself.
When `transfer abandon` releases a stale journal, the same fleet-lock section checks each stopped flag:
- It relaunches the source SecondMate only while the assignment generation and the parent binding still match the journal and no claimed transfer for that SecondMate is in progress.
- It restarts the destination manager only while no other unfinished journal reserves that manager.
- Any other flag is cleared, and the command reports which transfer now owns the endpoint.
`transfer-state` changes only the current `published` or `active` row for its exact transaction. It never adds a row, so a slow activation of a superseded transfer fails and cannot restore the old authority.
If a relaunch fails, `transfer abandon` and the exit trap exit non-zero. The endpoint's stopped flag stays in the journal, and the output names the `transfer abandon --transaction <id>` retry command.
The journal records `destination_stopped`. So if the owner-record move fails, `transfer rollback` also restarts that destination manager.
Explicit `--to` remains the administrative override. It requires an already stopped, unreserved destination and uses the same preflight and abandonment path.
`recover` selects its destination the same way, keeps that destination live, journals the move as a failover, and does not relaunch the destination manager.
A failover honors only planned-transfer reservations, because it does not stop its destination.
The command stops the SecondMate endpoint, writes a transaction journal under `<fleet-root>/transactions/`, moves the parent route and metadata, rewrites `.fm-secondmate-parent`, publishes the next assignment generation, restarts the destination manager, and relaunches the SecondMate from the destination home.
The assignment publishes after the owner records, so a crash cannot leave both parents authoritative.

```sh
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" transfer begin \
  --secondmate harness --source-home "$ORIGINAL_FIRSTMATE_HOME"
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" transfer begin \
  --secondmate harness --to manager-1 --source-home "$ORIGINAL_FIRSTMATE_HOME"
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" transfer recover \
  --transaction <transaction-id>
bin/fm-fleet.sh --fleet-root "$HOME/.fm-fleet" transfer rollback \
  --transaction <transaction-id>
```

Transfer recovery refuses while the source home has a live session lock, and while the destination home is live for a planned transfer or stopped for a failover.
Rollback refuses while either home has a live session lock.
Apply and rollback hold both homes' `state/.secondmate-registry.lock`, in sorted home order, while they edit only the transferred SecondMate's route line and endpoint records, so other routes added to either registry after the transfer survive.
Rollback restores the parent binding and restores the prior assignment only when the published generation still matches the transaction.
Lifecycle hooks named in `bin/fm-fleet.sh` let tests and a controlled pilot replace endpoint operations without weakening the default path.

No transfer copies or removes a SecondMate home, backlog, project checkout, worktree, or completion evidence.

## Migration Boundary

AutoDev and Paperclip stay available as reversible backstops while the fleet proves consumer-visible equivalence.
The fleet does not retire either system and does not become a wrapper around their reasoning.
