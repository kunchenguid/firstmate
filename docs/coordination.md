# Advisory coordination store

`bin/fm-coord.sh` implements the shadow coordination store and advisory integration queue.
It records intents, grants coarse resource claims, serializes final integration decisions, and returns durable receipts from one local SQLite database.
It is shadow/advisory only: the local adapters below record and warn at dispatch, push, and CI request checkpoints without blocking the selected delivery path.
The authority runs on one host with one local database under its `FM_HOME/state/` by default.
Only trusted callers should invoke it in this increment; enrollment is an administrative record, not remote authentication.
No network operation occurs in a database transaction.
The local adapter can invoke this command over batch SSH with fixed, quoted arguments; the SSH account and host trust remain operator configuration.
A copied database is an archive, not a second live authority.

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
After a release, expiry, or session revocation, the same home can claim the same intent under its current session generation and then call `queue-ready` again with a fresh fence.
An intent with an unsettled merge attempt or a recorded landing cannot be reclaimed.
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
Revoking a claim before a forge attempt releases any held slot with a `slot-claim-revoked` event and moves queued preparation to `repair-needed` for re-admission.
These pre-attempt transitions cannot release an in-flight or unknown forge attempt.

`queue-attempt` requires current head and base evidence, successful check evidence at the current manifest version, and explicit captain-hold, away, and merge-authority attestations.
It records the attempt event and returns the `bin/fm-pr-merge.sh` command for the owning task home.
The caller must run that existing guarded wrapper separately; this store never calls a lower-level merge operation.
The wrapper remains authoritative for live hold, away, check, and merge authority gates.
The attestations here are advisory until the step-4 dispatch and merge boundaries enforce this protocol.
A wrapper refusal or ambiguous reply reported through `queue-result` leaves the slot `outcome-unknown` until `queue-reconcile` proves landing or non-landing from the forge.
Caller-supplied refusal flags and base OIDs cannot settle an attempt.
`queue-reconcile` can settle an `attempting` slot directly only when the live forge read proves the exact head landed.
A refused candidate may re-enter `queue-ready` after its owner repairs the issue, creating a new attempt event without changing the prior terminal record.
A timeout or lost reply goes to `outcome-unknown`, retaining the slot across process restarts.
`queue-reconcile` uses read-only `gh-axi api` calls outside the SQLite transaction to read the exact GitHub PR and the current base OID.
A merged PR at the recorded head releases an unknown slot as `merged`.
An open or closed-unmerged PR that is neither in the merge queue nor armed for auto-merge releases it as `refused` only when the forge compare of the current base with the recorded head reports `ahead` or `diverged`, so the attempted head is not on base.
The PR is read again after the compare, and a changed state, merge flag, head, or base keeps the slot unknown.
Before any forge read toward a not-merged release, the recorded wrapper process must be proven gone, by a changed boot, an absent PID, or a changed process start time, and at least 10 minutes since the attempt; `FM_COORD_QUIET_SECONDS` changes that period for deterministic testing.
An attempt without a recorded wrapper identity, or whose identity cannot be checked, never leaves `outcome-unknown` as not merged.
Any other observation keeps the slot `outcome-unknown`, and the attempt event ID is unique in the terminal-outcome table.
`queue-operator-abort` is the only other way out of `outcome-unknown`: it records the named operator and reason in a `slot-operator-aborted` event and moves the item to `repair-needed` without a terminal outcome.
Replaying the same reconciliation request returns its stored receipt without another forge read.
This increment's live outcome reconciliation supports GitHub PRs; other forges need an equivalent read adapter before they can leave `outcome-unknown`.
The forge read and database transition are separate, so a direct external base update can still race this advisory decision until step-4 enforcement and repository protection are active.

## Events, schema and recovery

Every successful transition and every scope denial writes an event and outbox row in the same transaction as its state change or refusal receipt.
Each event has a stable UUID `event_id`, increasing local `seq`, event type, request correlation, JSON payload and central UTC creation time.
`outbox` lists unacknowledged events in sequence order; `ack` marks one event delivered without deleting it.
Replaying an unacknowledged event retains its original identity, while request replay creates no second event.
An inbox acknowledgment by a future transport means delivery, not a grant.
The database is authoritative; unrestricted status prose and notification cursors are projections.

Schema versions 1 and 2 live in `bin/fm-coord-migrations/001.sql` and `002.sql` and are applied transactionally through SQLite `user_version`.
The tables are `meta` for boot identity; `participants` for scoped sessions; `areas` and `area_aliases` for registry names; `intents` for versioned submissions; `claims`, `claim_resources`, and `branch_owners` for leases and fencing; `allocation_counters` and `allocations` for persistent migration identities; `heads` for immutable head submissions; `requests` for replay receipts; and `events` plus `outbox` for notifications.
Version 2 adds required-check manifests, queue items, one-slot records, integration generations, and unique terminal outcomes.
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
`submit` and `attach-pr` accept only an exact `https://github.com/<owner>/<repo>/pull/<number>` URL for the intent repository, and `queue-ready` refuses any other stored URL.
`migration-seed` includes `repo`, `namespace`, `next_number`, and `request_id`; `reserve` adds `namespace` and requires that namespace in the intent's resources.
`queue-ready` includes the writer identity, claim, fence, intent ID, and published head OID.
`queue-next` includes the repository and base; `queue-synced`, `queue-validated`, `queue-checks`, and `queue-attempt` add the returned `slot_generation` plus current head and base OIDs.
`queue-result` and `queue-reconcile` use the returned integration `generation` because they reconcile an already attempted forge operation after an owner may go offline.
`queue-reconcile` also includes the exact `pr_url` and `base`, plus the recorded `head_oid` to prove a non-landing; each is checked against the intent and queue item before accepting the live forge observation.
Payload fields starting with `_` are reserved for those forge observations and are refused.
`queue-abort` includes the slot generation and a reason, and is limited to the pre-attempt phases.
`queue-operator-abort` includes the integration `generation`, `operator`, and `reason`.
`queue-attempt` accepts an optional `wrapper_pid`: the live process on the coordinator host that then `exec`s `bin/fm-pr-merge.sh`, so its PID and start time identify the wrapper.
`outbox` accepts optional `after_seq` and `limit`; `ack` accepts `request_id` and `event_id`.
`inspect` gives a small state summary for operators.
`view` projects active intents, active claims, recent scope conflicts, the integration queue, and pending central outbox events as one JSON object.

## Local lifecycle adapter

Each participating home may opt in through the `config/coordination.json` schema in [configuration](configuration.md); both supported modes only record and warn.
The coordinator initializes the database with `bin/fm-coord.sh --db PATH init` before participants submit.
Same-host participants call the central database directly, while remote homes use the configured batch SSH transport to invoke the central command with quoted fixed arguments and an eight-second upper bound.
Do not copy a database into a second live authority.

A ship brief declares exactly one `Coordination resources:` line containing a JSON array of the resource objects above, and may declare one `Coordination issue:` line with its stable issue name.
In a home with `config/coordination.json`, `fm-brief.sh` scaffolds an empty array to make the declaration visible; fill it before spawn.
A brief that still declares an empty array is recorded locally as an unclaimed intent with a warning and is not submitted centrally.
`fm-spawn.sh` records the pre-dispatch intent and claim from that brief for Claude Code, Codex, omp, and OpenCode workers after it refreshes the task worktree, using the commit the worker starts at as the intent base; a fresh retry of the same task whose start commit moved releases the prior attempt's claim and submits a new intent at the retried start commit.
When the task worktree has no `origin/<base>` ref, the intent is recorded locally with no base and a warning, and is not submitted centrally.
A spawn that aborts before its worker launches releases any claim that dispatch acquired and drops the local intent's pending requests.
Both releases are journaled before they are sent; if the coordinator is unavailable, the release stays queued and linked to the task, `replay` resends it, and the retried attempt is not submitted until that release is recorded centrally.
The launch brief gives every supported harness the same `pre-push`, `pre-ci`, and `heartbeat` adapter commands, and asks workers to surface warnings through their existing task status.
`pre-push` compares the commit diff from the merge base of `origin/<base>` and HEAD, treating rename sources and destinations as separate paths, requests an amendment for undeclared paths, checks the live branch writer fence, and publishes the current head only when that fence is live and every changed path is claimed.
While an amendment is refused or pending, the head stays unpublished and both `pre-push` and `scope-amend` remain pending in `view`.
`pre-ci` checks the same fence before a `ci:batch` request and warns without clearing its pending checkpoint while the worktree HEAD differs from the published head, so CI is never authorized for an older head.
`check` returns the intent's latest central head, and the adapter refreshes its local published-head cache from it before comparing, so a lost `publish-head` reply cannot let an older worktree HEAD pass.
`pre-ci TASK` without a worktree uses the task's recorded worktree and refuses when none is recorded; `replay` skips a pending `pre-ci` with no recorded worktree and warns.
`heartbeat` checks the fence and renews the lease at a worker checkpoint; a lease that has already expired is reported as stale.
Missing adapters, undeclared resources, denied claims, stale fences, and offline central reads print warnings without granting authority or blocking the existing delivery path.

Use `FM_HOME=/path/to/home python3 bin/fm-coord-adapter.py replay` to retry a participant's locally journaled requests after an outage; it submits and claims only tasks whose dispatch is still pending and resumes checkpoints only for tasks that already hold a claim, so refused or finished tasks never reclaim resources, and `FM_HOME=/path/to/home python3 bin/fm-coord-adapter.py view` for the central projection plus local pending requests.
Each request is written to the home-local journal named in [configuration](configuration.md) before it is sent with a stable UUID; a lost reply reuses that UUID and receives the stored central receipt.
The file is serialized with a home-local lock and replaced atomically; a checkpoint that cannot take the lock within five seconds warns and skips.
An offline request remains pending and is never represented as a confirmed claim.
A refused claim or amendment is dropped from the journal, so the next checkpoint retries it with a new request ID.
A task whose declaration changes before any central submission is rerecorded with the new declaration.
When the coordinator reports an expired session generation, the adapter starts a fresh session and resets every local task to a new intent, which is submitted and claimed at that task's next dispatch or worker checkpoint; a claim that is no longer active resets that task the same way.
Stale `publish-head` requests are resent only by `pre-push` or `replay` in head order, so the published head chain stays consistent.
A head already published for the intent, such as after a reset to an earlier commit, is not republished; `pre-push` warns and the next new head chains from the latest central head.

The current test entry points are `bin/fm-test-run.sh tests/fm-coord.test.sh tests/fm-coord-queue.test.sh tests/fm-coord-adapter.test.sh`.
