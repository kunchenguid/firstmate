# Coordination store and opt-in enforcement

`bin/fm-coord.sh` implements the shadow coordination store and advisory integration queue.
It records intents, grants coarse resource claims, serializes final integration decisions, and returns durable receipts from one local SQLite database.
It defaults to shadow/advisory: the local adapters below record and warn at dispatch, push, and CI request checkpoints without blocking the selected delivery path.
One explicit `enforce_repos` switch in each participant home's configuration makes those checkpoints refuse for listed repositories.
The authority runs on one host with one local database under its `FM_HOME/state/` by default.
Only trusted callers should invoke it in this increment; enrollment is an administrative record, not remote authentication.
No network operation occurs in a database transaction.
The local adapter can invoke this command over batch SSH with fixed, quoted arguments; the SSH account and host trust remain operator configuration.
A copied database is an archive, not a second live authority.
The authority binds the database to its absolute path, serializes command invocations with a host lock, and keeps a separate high-water recovery marker beside the database.
It marks each transaction pending before the SQLite commit and clears the marker afterward, so a crash in that interval requires fenced recovery instead of guessing whether the commit happened.
The host-lock wait defaults to two seconds and `FM_COORD_LOCK_WAIT_SECONDS` accepts 0 to 3, below the adapter's five-second direct-call bound, so a contended caller refuses before its client can kill it inside that interval.

## Identity and intent contract

`home_id` is a persistent identity for an independent Firstmate home and is unrelated to its agent harness.
`enroll` records its allowed repository IDs; `session` returns a fresh session ID and increasing `generation`.
Starting a new session revokes that home's active claims, while retained branches and worktrees remain untouched.
Every caller operation carries the current `home_id` and `generation`; a prior generation cannot renew, amend, release, reserve, or publish a head.
The central command uses its OS boot identity and monotonic clock for lease deadlines.
On reboot it revokes active claims, increments participant generations, and requires new sessions before authority can be reacquired.
V1 has one active coordinator and no automatic standby takeover; fencing numbers from copied databases cannot fence each other.

`submit` records `intent.v1` with `intent_id`, `repo`, `base`, full `base_oid`, `home_id`, `generation`, `task_id`, `branch`, optional `issue` and `pr_url`, short `goal`, nonempty write `resources`, and optional `read_dependencies`, `predecessors`, and `expected_artifacts` arrays.
Submit stores the canonical resource set and leaves the intent `submitted`; it never grants a claim.
When `issue` is present, submission automatically includes an issue claim in the canonical set, and `amend` keeps it without the caller restating it.
The planned PR URL may be absent at submission; `attach-pr` records a full HTTPS URL whose `owner/repo` path matches the intent `repo` under the current branch writer claim and does not permit replacement with a different URL.
`predecessors` names already submitted intents on the same repository and base.
`predecessors-set` can change the list before an intent is queued, and refuses a cycle.
Do not put raw prompts, credentials, secret projections, or full transcripts in a payload.
`request_id` is a caller-generated stable idempotency key for every mutation, unique within its `home_id` or the administrative `@authority` actor; a `home_id` cannot start with `@`, so the two namespaces never collide.
Reusing the key with identical operation and payload returns the exact stored result; reusing it for different content fails.
The prior grant receipt can be replayed after a lease expires, but it cannot revive the grant: use `check` with the live fence before acting.

Resources are objects with `type` and `name`, except `rename` with `from` and `to` paths.
Repository paths use relative POSIX syntax; repeated separators and `.` collapse, while absolute paths, backslashes and `..` fail.
File, directory, dependency-manifest and generated-output resources share the path conflict domain; the last two canonicalize to files.
Equal paths overlap; a directory also overlaps any descendant file or directory.
`rename` expands to directory claims on both old and new paths, so it covers a renamed file and every descendant of a renamed directory.
`issue`, `schema-object`, `migration-sequence`, and `integration` overlap by exact type and canonical name.
Use one stable issue spelling such as `owner/repo#123`; this increment does not look up forge aliases.
An `area` resolves through the repository area registry to its canonical name and declared directory prefixes.
All aliases of that area therefore claim the same name and paths.
Area definitions are immutable and cannot be added while that repository has active claims; this avoids a registry edit changing the meaning of an existing grant.
Path claims do not resolve filesystem symlinks, so area definitions must cover any relevant aliasing deliberately.

`claim` checks all canonical resources and branch writer ownership in one `BEGIN IMMEDIATE` transaction.
It grants all requested resources and one branch writer with a monotonic fence, or returns `ok:false`, `reason:scope-conflict`, and the conflicting owner's home, intent, claim, and resource.
Independent files on separate branches are admitted concurrently.
`amend` adds scope atomically and increments the intent version; it cannot silently drop an existing resource.
`publish-head` stores an immutable full Git object ID after checking the current writer claim and exact previous head.
It records a candidate for the queue; the queue itself never runs a merge.
No arbitrary editor write is brokered, so local editing remains cooperative.

Claims default to a 900-second lease, with a caller heartbeat recommended every 60 seconds.
`renew` requires the exact active claim, participant generation, intent version and fence.
`release` has the same fence checks and cannot delete a later holder's claim.
Expiry and session replacement revoke authority and branch writer ownership, never local work.
Lease expiry is committed with its outbox event before the requested operation runs, so a refused late `renew` still leaves the claim expired.
The short lease does not erase a migration number reservation.
Before a namespace's first `reserve`, the operator must inspect the repository's existing migration numbering and use `migration-seed` with the first unused number.
Each reservation has a durable allocation ID and unique `(repo, namespace, number)`; numbers increase without reuse even after the claim expires.
The later integration gate must compare allocations with actual main and applied migrations before landing.

## Advisory integration queue

`manifest-set` records a nonempty repository-owned required-check list for one `(repo, base)` and increments its version.
`queue-ready` needs the active writer claim, an attached PR, and the latest published head.
It records the immutable candidate head and a priority from 0 through 9.
`queue-next` atomically grants one integration slot per `(repo, base)` to a dependency-safe ready item.
It orders eligible items by priority plus one aging point per 60 ready seconds, then ready time and intent ID.
`FM_COORD_AGING_SECONDS` changes the interval for deterministic testing.
A not-ready or blocked predecessor does not occupy the slot, and an independent ready item can proceed.
The integration generation fences stale phase reports.

The slot moves through `syncing`, `validating`, `awaiting-checks`, `attempting`, and optionally `outcome-unknown` before a terminal `merged` or `refused` outcome.
`queue-synced` records the current base OID after the owning home attests that the published head contains it.
`queue-validated` records a passing final validation ID for that exact head and base.
`queue-checks` requires every named manifest check to have one successful result at the exact head, plus any additional required checks exposed by forge protection.
An unreadable or empty rollup fails closed, including when the forge cannot expose protection settings.
Every phase read compares the latest published head with the live head supplied by the caller; validation, checks, and attempt also compare the live base with the recorded base.
A mismatch releases preparation into `sync-needed`, and `queue-abort` releases an unattempted slot for an explicit reason.
Neither operation can release an in-flight or unknown forge attempt.

`queue-attempt` requires current head and base evidence, successful check evidence at the current manifest version, and explicit captain-hold, away, and merge-authority attestations.
It records the attempt event and returns the `bin/fm-pr-merge.sh` command for the owning task home.
The caller must run that existing guarded wrapper separately; this store never calls a lower-level merge operation.
The wrapper remains authoritative for live hold, away, check, and merge authority gates.
The attestations here are advisory until the step-4 dispatch and merge boundaries enforce this protocol.
A successful wrapper result can be confirmed with `queue-reconcile`; a definitive wrapper refusal can be recorded with `queue-result`.
A refused candidate may re-enter `queue-ready` after its owner repairs the issue, creating a new attempt event without changing the prior terminal record.
A timeout or lost reply goes to `outcome-unknown`, retaining the slot across process restarts.
`queue-reconcile` uses read-only `gh-axi api` calls outside the SQLite transaction to verify that the exact GitHub PR is merged at the recorded head and to read the current base OID.
Only that proved landing releases an unknown slot, and the attempt event ID is unique in the terminal-outcome table.
Replaying the same reconciliation request returns its stored receipt without another forge read.
This increment's live outcome reconciliation supports GitHub PRs; other forges need an equivalent read adapter before they can leave `outcome-unknown`.
The forge read and database transition are separate, so a direct external base update can still race the decision; repository protection and exact-head forge guards remain necessary.

## Events, schema and recovery

Every successful transition and every scope denial writes an event and outbox row in the same transaction as its state change or refusal receipt.
Each event has a stable UUID `event_id`, increasing local `seq`, event type, request correlation, JSON payload and central UTC creation time.
`outbox` lists unacknowledged events in sequence order; `ack` marks one event delivered without deleting it.
Replaying an unacknowledged event retains its original identity, while request replay creates no second event.
An inbox acknowledgment by a future transport means delivery, not a grant.
The database is authoritative; unrestricted status prose and notification cursors are projections.

Schema versions 1 through 4 live in `bin/fm-coord-migrations/` and are applied transactionally through SQLite `user_version`.
The tables are `meta` for boot identity; `participants` for scoped sessions; `areas` and `area_aliases` for registry names; `intents` for versioned submissions; `claims`, `claim_resources`, and `branch_owners` for leases and fencing; `allocation_counters` and `allocations` for persistent migration identities; `heads` for immutable head submissions; `requests` for replay receipts; and `events` plus `outbox` for notifications.
Version 2 adds required-check manifests, queue items, one-slot records, integration generations, and unique terminal outcomes.
Version 3 adds one CI pulse authorization per `(repo, base, batch_id)`.
Version 4 adds fenced CI batch identities that manual recovery restores from the marker.
A future schema change must add a numbered migration and preserve earlier receipts and allocation identities.
The command refuses a database with a newer or uninitialized schema.
SQLite's single-writer transaction lock serializes concurrent claim requests on this one local database.
Transactions contain no network call, editor work, CI run or LLM wait.
The `sqlite3` command and Python 3 standard library must be available on macOS or Linux; missing tools fail clearly.

## Command use

All commands emit one JSON object on stdout and an error on stderr with nonzero exit status for invalid requests.
Run `bin/fm-coord.sh --help` for the current command list.
`--db PATH` selects an explicit local database for tests or one authority; otherwise set `FM_HOME` for `state/fm-coord.sqlite3`.
Initialize with `bin/fm-coord.sh init`.
Then use `enroll {"request_id":"enroll-a","home_id":"home-a","repos":["owner/repo"]}` and `session {"request_id":"session-a","home_id":"home-a"}`.
An administrative area definition uses `area-set {"request_id":"area-a","repo":"owner/repo","name":"api","paths":["src/api"],"aliases":["server-api"]}`.
An intent uses `submit {"request_id":"submit-a","intent_id":"task-a","home_id":"home-a","generation":1,"repo":"owner/repo","base":"main","base_oid":"0000000000000000000000000000000000000000","branch":"task/a","task_id":"a","goal":"Update API","resources":[{"type":"area","name":"api"}]}`.
Its `claim` payload includes `request_id`, `intent_id`, `home_id`, `generation`, and `version`.
`renew`, `release`, and `check` include `home_id`, `generation`, `claim_id`, and `fence`; mutating forms also include `request_id`.
`amend`, `reserve`, `publish-head`, and `attach-pr` additionally include `intent_id`.
`attach-pr` includes `pr_url` and the live `claim_id` and `fence`.
`migration-seed` includes `repo`, `namespace`, `next_number`, and `request_id`; `reserve` adds `namespace` and requires that namespace in the intent's resources.
`queue-ready` includes the writer identity, claim, fence, intent ID, and published head OID.
`queue-next` includes the repository and base; `queue-synced`, `queue-validated`, `queue-checks`, and `queue-attempt` add the returned `slot_generation` plus current head and base OIDs.
`queue-result` and `queue-reconcile` use the returned integration `generation` because they reconcile an already attempted forge operation after an owner may go offline.
`queue-reconcile` also includes the exact `pr_url` and `base`, which are checked against the immutable intent before accepting the live forge observation.
`queue-abort` includes the slot generation and a reason, and is limited to the pre-attempt phases.
`outbox` accepts optional `after_seq` and `limit`; `ack` accepts `request_id` and `event_id`.
`pulse-batch` accepts the current writer claim, `intent_id`, published `head_oid`, and a stable `batch_id`; a second request for that batch receives `batch-already-pulsed`.
`merge-guard` accepts a PR URL and head OID and confirms an active attempting slot, current writer claim, and exact queued head.
`inspect` gives a small state summary for operators.
`view` projects active intents, active claims, recent scope conflicts, the integration queue, and pending central outbox events as one JSON object.

## Local lifecycle adapter

Each participating home may opt in through the `config/coordination.json` schema in [configuration](configuration.md); repositories absent from `enforce_repos` only record and warn.
The coordinator initializes the database with `bin/fm-coord.sh --db PATH init` before participants submit.
Same-host participants call the central database directly, while remote homes use the configured batch SSH transport to invoke the central command with quoted fixed arguments and an eight-second upper bound.
Do not copy a database into a second live authority.

A ship brief declares exactly one `Coordination resources:` line containing a nonempty JSON array of the resource objects above, and may declare one `Coordination issue:` line with its stable issue name.
`fm-brief.sh` scaffolds an empty array to make the declaration visible; fill it before a coordinated spawn.
`fm-spawn.sh` records the pre-dispatch intent and claim from that brief for Claude Code, Codex, omp, and OpenCode workers.
The launch brief gives every supported harness the same `pre-push`, `pre-ci`, and `heartbeat` adapter commands, and asks workers to surface warnings through their existing task status.
`pre-push` compares the commit diff from the declared base OID to HEAD, treating rename sources and destinations as separate paths, requests an amendment for undeclared paths, checks the live branch writer fence, and publishes the current head when that fence is live.
`pre-ci TASK [BATCH]` checks the same fence and records one authorization for the stable batch ID before a `ci:batch` request; omitting `BATCH` uses the task ID.
An enforced repository refuses a second request for the same batch, an unconfirmed request, or a stale writer generation.
`readmit TASK WORKTREE` explicitly retries a denied claim or scope amendment after the coordinator has resolved the conflict.
When the central claim is no longer active after lease expiry, a coordinator reboot or manual recovery, `readmit` opens a new session with new request IDs if the home's generation changed, then submits and claims a fresh intent for the task.
A journaled `pre-ci` request without a reply is replayed with its original request ID on the next `pre-ci` for that batch.
A lifecycle checkpoint for a repository outside `enforce_repos` warns and exits 0 on any adapter error; an enforced repository or an unreadable coordination config refuses.
Dispatch records each task's repository before validating its declaration, so a shadow task without a full intent keeps its repository's exit rule.
`pre-push` for a task this home never dispatched resolves the repository from its worktree, and `pre-ci` for one refuses whenever the home enforces any repository.
A readmitted task keys its journaled `pre-ci` and renewal requests by the new admission and drops unanswered requests that carry the revoked claim, so they are never replayed or left pending.
`fm-pr-merge.sh` calls `pre-merge TASK PR_URL HEAD` immediately before the forge merge for an enforced GitHub repository, and refuses an absent, stale, or unreachable integration slot.
For a task this home dispatched, `pre-merge` first attaches the PR and advances the task's queue item through `queue-ready`, `queue-next`, `queue-synced`, `queue-validated`, `queue-checks`, and `queue-attempt` from the observed central state, so an ordinary ship landing reaches the attempting slot without operator queue commands.
The merge head must be the head published by `pre-push`; the wrapper's live pull request view supplies the base OID, check rollup, and final validation for that head, and the wrapper's captain-hold, away, and merge-authority checks supply the attempt attestations.
A local worktree that does not contain the current base, a missing required-check manifest, or a slot held by another candidate refuses the merge.
`heartbeat` checks the fence and renews the lease at a worker checkpoint; a lease that has already expired is reported as stale.
Missing adapters, undeclared resources, denied claims, stale fences, and offline central reads print warnings in shadow mode and refuse the checkpoint in enforced mode.
The worker must run `pre-push` before a direct push or a no-mistakes pipeline that pushes on its behalf, and must run `pre-ci` before its CI request.
The coordinator does not alter repository workflow triggers or GitHub settings.

Use `FM_HOME=/path/to/home python3 bin/fm-coord-adapter.py replay` to retry a participant's locally journaled requests after an outage, and `FM_HOME=/path/to/home python3 bin/fm-coord-adapter.py view` for the central projection plus local pending requests.
Each request is written to the home-local journal named in [configuration](configuration.md) before it is sent with a stable UUID; a lost reply reuses that UUID and receives the stored central receipt.
The file is serialized with a home-local lock and replaced atomically.
An offline request remains pending and is never represented as a confirmed claim.

The current test entry points are `bin/fm-test-run.sh tests/fm-coord.test.sh tests/fm-coord-queue.test.sh tests/fm-coord-adapter.test.sh tests/fm-coord-enforce.test.sh`.

## Rollout and 48-hour comparison

Start with two independent homes in `shadow` mode and an empty `enforce_repos` list.
Record all submitted intents, denied claims, amendments, writer generations, outbox deliveries, and integration outcomes without changing the existing merge route.
Import every current work-in-progress branch as an explicit `submit` intent with its current base, head context, owner, issue, and resource list; leave it unclaimed until its scope has been reviewed and admitted.
Do not infer ownership from a branch name or silently claim the imported work.
Resolve overlapping imports with their owners, then select one repository and set `enforce_repos` to that repository in every participating home and integration home.
Keep all other repositories shadowed.
Before enforcement, verify that the participating repository's ordinary branch pushes do not trigger workflow fan-out and that CI uses one explicit `ci:batch` pulse per coherent batch.
The coordinator's `pulse-batch` receipt is a single authorization, not a workflow dispatch; the caller records the workflow run URL against the batch and must not issue a second pulse when the receipt is replayed.

Measure the next fixed 48-hour UTC window with exact start and end timestamps.
Count forge runs created in each window by conclusion, preserving run URL, head OID, started time, and updated time, and report failed plus cancelled as a count and percentage separately from summed elapsed workflow-hours.
The prior forensics window was 2026-10-01T09:23:50Z through 2026-10-03T09:23:50Z, with 829 runs, 144 failures, 42 cancellations, and 41.32 summed elapsed hours for those 186 unsuccessful runs.
That elapsed sum is neither runner cost nor proven avoidable waste.
Count executed rebases from timestamped command results, deduplicated by task, branch, and event ID; count duplicate work by issue ownership and overlapping accepted intents, with source links.
The forensics reports did not establish reliable baseline rebase or duplicate-work counts, so reconstruct them with the same method before claiming a before-and-after change.
Report blocked admission time, useful concurrent work, ordinary-push workflow runs, and number of pulses per batch beside the reliability counts.

## Backup and fenced recovery

Back up a live authority through SQLite's consistent `.backup` operation and retain `coord.sqlite3.authority.json` and the exact backup timestamp with it.
Keep the host lock file at the canonical path; it is an OS coordination point, not a backup data source.
An older restored database fails ordinary reads and writes when its event sequence falls behind the marker, an interrupted transaction remains paused, and a copied database at another path fails its path binding.
Do not lower or replace the marker to make a restore appear current.
For manual recovery, first stop participant traffic and verify that no coordinator command or forge attempt is still active; preserve the current database, marker, outbox, and any unknown merge attempts before restoring.
After restoring the selected backup to its original absolute path, run `bin/fm-coord.sh --db PATH recover '{"confirm":"FENCE_AND_REENROLL"}'` only under that fenced maintenance window.
The marker also records high-water marks for migration allocation counters, integration slot generations, and authorized CI batch IDs.
Recovery revokes all active claims, advances participant generations beyond the marker's recorded high-water generations, advances the event sequence, every allocation counter, and every slot generation past its recorded high-water mark plus a gap of ten, refuses every recorded CI batch ID, invalidates preparation slots, retains uncertain forge attempts as `outcome-unknown`, and creates a new authority identity and marker.
Re-enroll participant sessions with new request IDs, replay the outbox by stable event ID, reconcile each unknown forge outcome against its exact PR and head, and re-admit intents before enabling integration.
If the marker is missing or the restored database's authority identity differs, stop and investigate the backup lineage rather than creating a second live authority.
