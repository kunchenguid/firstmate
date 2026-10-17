# Advisory coordination store

`bin/fm-coord.sh` is the first increment of the central Firstmate coordination protocol.
It records intents, grants coarse resource claims, and returns durable receipts from one local SQLite database.
It is shadow/advisory only: no dispatch, push, CI request, or merge path calls it yet.
The authority runs on one host with one local database under its `FM_HOME/state/` by default.
Only trusted local callers should invoke it in this increment; enrollment is an administrative record, not remote authentication.
No network operation occurs in a database transaction.
The intended later transport is an authenticated fixed-argument entrypoint that invokes this command against the central database.
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
The planned PR URL may be absent at submission; `attach-pr` records a full HTTPS URL whose path is the full intent `repo` path (any GitLab group depth) followed by `pull/<n>` or `-/merge_requests/<n>` under the current branch writer claim and does not permit replacement with a different URL.
This increment has no integration queue record.
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
It records a candidate only; final synchronization, validation and merge belong to the next V1 increment.
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

## Events, schema and recovery

Every successful transition and every scope denial writes an event and outbox row in the same transaction as its state change or refusal receipt.
Each event has a stable UUID `event_id`, increasing local `seq`, event type, request correlation, JSON payload and central UTC creation time.
`outbox` lists unacknowledged events in sequence order; `ack` marks one event delivered without deleting it.
Replaying an unacknowledged event retains its original identity, while request replay creates no second event.
An inbox acknowledgment by a future transport means delivery, not a grant.
The database is authoritative; unrestricted status prose and notification cursors are projections.

Schema version 1 lives in `bin/fm-coord-migrations/001.sql` and is applied transactionally through SQLite `user_version`.
The tables are `meta` for boot identity; `participants` for scoped sessions; `areas` and `area_aliases` for registry names; `intents` for versioned submissions; `claims`, `claim_resources`, and `branch_owners` for leases and fencing; `allocation_counters` and `allocations` for persistent migration identities; `heads` for immutable head submissions; `requests` for replay receipts; and `events` plus `outbox` for notifications.
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
`outbox` accepts optional `after_seq` and `limit`; `ack` accepts `request_id` and `event_id`.
`inspect` gives a small state summary for operators.

The current test entry point is `bin/fm-test-run.sh tests/fm-coord.test.sh`.
