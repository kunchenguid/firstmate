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
`request_id` is a caller-generated stable idempotency key for every mutation, unique within its `home_id` or administrative actor (`@authority`, or `@authority:<account>:<uid>` for operator abort); a `home_id` cannot start with `@`, so the two namespaces never collide.
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
Before any forge read toward a not-merged release, a same-host wrapper must be proven gone by a changed boot, an absent PID, or a changed process start time, and at least 10 minutes must have passed since the attempt; `FM_COORD_QUIET_SECONDS` changes that period for deterministic testing.
A remote wrapper needs a `queue-wrapper-exited` event from its owning participant's current session, even if that session started after the attempt, and the same quiet period after that exit attestation; the coordinator never checks a foreign host's PID locally.
The exit event must match the recorded attempt, home, host ID, PID, and start time, and the later forge read must still prove non-landing.
Without the attestation or an authority-only operator abort, a remote attempt remains `outcome-unknown`.
The shadow command verifies the enrolled participant session for the exit event; an authenticated transport adapter must bind the remote caller to that home before forwarding it in step 3.
The exit report is an attestation from the enrolled participant adapter, the only party able to check its own process: the adapter's `wrapper-exited` command refuses while a process with that exact PID and start time remains on its host, then sends `exit_verified_host_id` set to its enrolled host ID.
The coordinator checks the PID itself only when the participant's enrolled host is the coordinator's own machine; otherwise it refuses an exit report without an `exit_verified_host_id` that equals the enrolled host, so a PID absent on the coordinator proves nothing.
A lying enrolled participant is outside the threat model; the coordinator still requires the attestation, the quiet period, and live forge proof of non-landing.
A lost exit reply replays its original receipt with the same `request_id` from the owning home's current session, because the replay key covers the attempt and exact wrapper identity rather than the participant generation; a stale session or a different attempt or wrapper identity is refused.
Any other observation keeps the slot `outcome-unknown`, and the attempt event ID is unique in the terminal-outcome table.
`queue-operator-abort` is the only other way out of `outcome-unknown`: the enrolled authority actor records a reason in a `slot-operator-aborted` event and moves the item to `repair-needed` without a terminal outcome.
The command requires the authority credential before looking up a replay receipt, refuses participant identities and caller-supplied operator names, and records the process's authenticated local account and effective UID as `@authority:<account>:<uid>`.
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

Schema versions 1 through 8 live in the corresponding numbered files under `bin/fm-coord-migrations/` and are applied transactionally through SQLite `user_version`.
The tables are `meta` for boot identity and the authority credential digest; `participants` for scoped sessions; `areas` and `area_aliases` for registry names; `intents` for versioned submissions; `claims`, `claim_resources`, and `branch_owners` for leases and fencing; `allocation_counters` and `allocations` for persistent migration identities; `heads` for immutable head submissions; `requests` for replay receipts; and `events` plus `outbox` for notifications.
Version 2 adds required-check manifests, queue items, one-slot records, integration generations, and unique terminal outcomes.
Version 3 adds one CI pulse authorization per `(repo, base, batch_id)`.
Version 4 adds fenced CI batch identities that manual recovery restores from the marker.
Version 5 adds recorded wrapper identity and attempt time to queue items.
It also recognizes the complete set of those columns in previously patched databases, while refusing a partial or incompatible set for manual repair.
Version 6 binds participant homes to host IDs and records whether a wrapper was local or remote, plus any remote exit attestation.
Earlier active attempts are classified as local because all prior attempts required a coordinator-local PID.
Existing participants without a host ID must bind one through `enroll` before a new attempt; a bound host ID cannot change.
Version 7 replaces the hostname with a durable machine identity, a 32-character lowercase hexadecimal `/etc/machine-id` on Linux or `IOPlatformUUID` on macOS, so a hostname change cannot turn a same-host home remote; the coordinator refuses to initialize or enroll a same-host home when that identity is missing, empty, `uninitialized`, malformed, or unreadable through `ioreg`.
The migration rebinds a participant whose version-6 host ID equals the coordinator's current hostname to the machine identity and clears every other host ID, so each such home must bind again once through `enroll` before its next attempt; the adapter's `attempt` command does this itself when the coordinator refuses for a missing host ID, enrolling again once and retrying the attempt once.
It leaves recorded attempts, including their local or remote classification and host ID, unchanged.
Version 8 adds per-repository CI admission capacity with its slot lease, and the queued or active CI heads it governs.
Published migrations are append-only: a schema change adds a higher-numbered migration and never renumbers or edits a published one, and a column a migration adds is skipped when the table already has it, so an existing database upgrades with its receipts, allocation identities, and CI batches intact.
Databases created by the step-3 adapter branch or by an earlier head of the step-4 change, which numbered these migrations differently, are not supported and must be recreated.
The command refuses a database with a newer or uninitialized schema.
SQLite's single-writer transaction lock serializes concurrent claim requests on this one local database.
Transactions contain no network call, editor work, CI run or LLM wait.
The `sqlite3` command and Python 3 standard library must be available on macOS or Linux; missing tools fail clearly.

## Command use

All commands emit one JSON object on stdout and an error on stderr with nonzero exit status for invalid requests.
Run `bin/fm-coord.sh --help` for the current command list.
`--db PATH` selects an explicit local database for tests or one authority; otherwise set `FM_HOME` for `state/fm-coord.sqlite3`.
Initialize with `FM_COORD_AUTHORITY_TOKEN=<private-random-token> bin/fm-coord.sh init` to enroll an authority credential of at least 32 characters.
The database stores only its SHA-256 digest; keep the token private to the authority host and supply the same environment variable for `queue-operator-abort`.
An initialization without the token leaves operator abort disabled until a later `init` with the token enrolls it once and records an `authority-enrolled` event with the local account identity; repeating `init` with the same token changes nothing, and a different token is refused rather than replacing the enrolled one.
Then use `enroll {"request_id":"enroll-a","home_id":"home-a","repos":["owner/repo"]}` and `session {"request_id":"session-a","home_id":"home-a"}`.
An enrollment without `host_id` binds the coordinator's machine identity for a same-host home; a remote home supplies a unique `host_id` that remains bound to that participant.
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
`queue-operator-abort` includes the integration `generation` and `reason`; its actor comes from the enrolled authority credential rather than the payload.
`queue-attempt` requires `wrapper_pid` and records the enrolled participant home and host ID; for a same-host home it reads the live process start time before returning the existing `bin/fm-pr-merge.sh` command.
For a remote home, the authenticated adapter supplies `wrapper_start` along with `wrapper_pid`, and the coordinator records that identity without inspecting the PID locally.
`queue-wrapper-exited` includes `request_id`, `intent_id`, `home_id`, participant `generation`, `slot_generation`, `attempt_event_id`, `wrapper_host_id`, `wrapper_pid`, and `wrapper_start` from that remote attempt, plus `exit_verified_host_id` from the participant adapter.
`outbox` accepts optional `after_seq` and `limit`; `ack` accepts `request_id` and `event_id`.
`pulse-batch` accepts the current writer claim, `intent_id`, published `head_oid`, and a stable `batch_id`; a second request for that batch receives `batch-already-pulsed`.
CI admission capacity is opt-in per repository and off by default: until `ci-capacity-set {"request_id":...,"repo":"owner/repo","capacity":4,"ttl_seconds":3600}` is run, every `pulse-batch` is admitted at once.
The capacity counts every base ref of the repository together, because they share its runners; `ttl_seconds` is optional and defaults to 3600.
With a capacity, `pulse-batch` reserves an active-head slot for that immutable head before authorizing it; when every slot is taken it queues the head and replies `admitted:false` with its queue `position`, and a second batch for a head that holds, awaits, or ever held a slot in that repository receives `head-already-admitted`, so a completed run never pulses its head again.
A head keeps its slot, even after its run turns red or its claim ends, until its run completes or its slot lease lapses.
`queue-checks` that records the head's required checks green completes its run; `ci-complete {"request_id":...,"repo":...,"head_oid":...,"conclusion":"success|failure|cancelled|timed_out"}` reports any other terminal run; and a slot held longer than `ttl_seconds` is released as `lease-expired` on the repository's next `pulse-batch`, `ci-complete`, or `ci-capacity-set`, so a lost completion cannot hold a slot forever.
Each release emits `ci-completed` and admits the oldest queued heads into the free slots, each with one `ci-pulse-authorized` event; a queued head whose intent no longer holds an active claim or whose published head has moved on is dropped with `ci-pulse-dropped` instead.
The first `pulse-batch` for a promoted batch returns that authorization with `admitted:true`; a lost reply replays it by request ID, and any later request receives `batch-already-pulsed`, so a duplicate never pulses twice.
`merge-guard` accepts a PR URL and head OID and confirms an active attempting slot, current writer claim, and exact queued head.
`inspect` gives a small state summary for operators.
`view` projects active intents, active claims, recent scope conflicts, the integration queue, and pending central outbox events as one JSON object.

## Local lifecycle adapter

Each participating home may opt in through the `config/coordination.json` schema in [configuration](configuration.md); repositories absent from `enforce_repos` only record and warn.
The coordinator initializes the database with `bin/fm-coord.sh --db PATH init` before participants submit.
Same-host participants call the central database directly, while remote homes use the configured batch SSH transport to invoke the central command with quoted fixed arguments and an eight-second upper bound.
A remote home enrolls with its own machine identity as `host_id`, computed only when the `enroll` request is first journaled and reused from the journal afterward; if that identity is unavailable, the adapter warns and does not enroll.
Do not copy a database into a second live authority.

A ship brief declares exactly one `Coordination resources:` line containing a JSON array of the resource objects above, and may declare one `Coordination issue:` line with its stable issue name.
In a home with `config/coordination.json`, `fm-brief.sh` scaffolds an empty array to make the declaration visible; fill it before spawn.
A brief that still declares an empty array is recorded locally as an unclaimed intent with a warning and is not submitted centrally.
`fm-spawn.sh` records the pre-dispatch intent and claim from that brief for Claude Code, Codex, omp, and OpenCode workers after it refreshes the task worktree, using the commit the worker starts at as the intent base; a fresh retry of the same task whose start commit moved releases the prior attempt's claim and submits a new intent at the retried start commit.
When the task worktree has no `origin/<base>` ref, the intent is recorded locally with no base and a warning, and is not submitted centrally.
A spawn that aborts before its worker launches releases any claim that dispatch acquired and drops the local intent's pending requests.
Both releases are journaled before they are sent; if the coordinator is unavailable, the release stays queued and linked to the task, `replay` resends it, and the retried attempt is not submitted until that release is recorded centrally.
The launch brief of every ship task in a coordinated home gives the same `pre-push`, `pre-ci`, and `heartbeat` adapter commands, and asks workers to surface warnings through their existing task status.
`pre-push` compares the commit diff from the merge base of `origin/<base>` and HEAD, treating rename sources and destinations as separate paths, requests an amendment for undeclared paths, checks the live branch writer fence, and publishes the current head only when that fence is live and every changed path is claimed.
While an amendment is refused or pending, the head stays unpublished and both `pre-push` and `scope-amend` remain pending in `view`.
`pre-ci TASK [BATCH [WORKTREE]]` checks the same fence and records one authorization for the stable batch ID before a `ci:batch` request; omitting `BATCH` uses the task ID.
It refuses to pulse, and keeps its pending checkpoint, while the worktree HEAD differs from the published head, so CI is never authorized for an older head.
Every `pre-ci`, including one that hands over an authorization `replay` received, rechecks the live lease and that the worktree HEAD is the exact head the batch was admitted for; an expired lease or a moved HEAD refuses that batch, and the task must run `pre-push` again and pulse a new batch.
When the repository's CI capacity is full, `pre-ci` reports the batch's queue position and keeps the checkpoint pending (an enforced repository refuses); rerunning `pre-ci` for the same batch polls with a fresh request and clears the checkpoint once the batch is admitted.
`check` returns the intent's latest central head, and the adapter refreshes its local published-head cache from it before comparing, so a lost `publish-head` reply cannot let an older worktree HEAD pass.
`pre-ci` without a worktree uses the task's recorded worktree and refuses when none is recorded; `replay` skips a pending `pre-ci` with no recorded worktree and warns.
`heartbeat` checks the fence and renews the lease at a worker checkpoint; a lease that has already expired is reported as stale.
`attempt TASK JSON` adds the live claim, intent, and the wrapper start time read on this host to the caller's `queue-attempt` slot and gate fields, and prints the central reply; it is not resent by `replay`, because an attempt is bound to a live wrapper.
`wrapper-exited TASK JSON` takes the `queue-wrapper-exited` attempt and wrapper fields, refuses while that wrapper process still runs on this host, then reports the exit with this home's host attestation and prints the central reply.
`attempt` records a remote attempt's intent ID, attempt ID, and wrapper identity on the task until `wrapper-exited` reports it. A session reset, coordinator restart, or new start commit still gives the task a fresh intent and fresh submit, claim, and checkpoint requests, but keeps that attempt record and its journaled exit request, so `wrapper-exited` reports against the recorded attempt with the same request ID from the new session; `replay` does not resend it.
An enforced repository refuses a second request for the same batch, an unconfirmed request, or a stale writer generation.
`readmit TASK WORKTREE` explicitly retries a denied claim or scope amendment after the coordinator has resolved the conflict, then rechecks scope and publishes the head.
When the central claim is no longer active after lease expiry, or the session generation expired after a coordinator reboot or manual recovery, any checkpoint (including `readmit`) gives the task a fresh intent and fresh request IDs as described below, so a revoked claim's unanswered renew and pulse requests are dropped rather than replayed.
A journaled `pre-ci` request without a reply is replayed with its original request ID on the next `pre-ci` for that batch.
A lifecycle checkpoint for a repository outside `enforce_repos` warns and exits 0 on any adapter error; an enforced repository or an unreadable coordination config refuses.
Dispatch records each task's repository before validating its declaration, so a shadow task without a full intent keeps its repository's exit rule.
`pre-push` for a task this home never dispatched resolves the repository from its worktree, and `pre-ci` for one refuses whenever the home enforces any repository.
`fm-pr-merge.sh` calls `pre-merge TASK PR_URL HEAD` immediately before the forge merge for an enforced GitHub repository, and refuses an absent, stale, or unreachable integration slot.
For a task this home dispatched, `pre-merge` first attaches the PR and advances the task's queue item through `queue-ready`, `queue-next`, `queue-synced`, `queue-validated`, `queue-checks`, and `queue-attempt` from the observed central state, so an ordinary ship landing reaches the attempting slot without operator queue commands; the final step goes through `attempt` with the merge wrapper as its parent process.
The merge head must be the head published by `pre-push`; the wrapper's live pull request view supplies the base OID, check rollup, and final validation for that head, and the wrapper's captain-hold, away, and merge-authority checks supply the attempt attestations.
The forge's comparison of the merge head with that base OID decides whether the head contains the current base, so a task worktree that has not fetched the base cannot refuse the merge.
An unavailable comparison, such as a rate-limited or 5xx forge reply, is unknown rather than proof the head lacks the base: `pre-merge` pauses queue synchronization with that reason, keeps the slot, and resumes when the merge is retried.
A head the forge does not report as containing the current base, a missing required-check manifest, or a slot held by another candidate refuses the merge.
After the forge call, `fm-pr-merge.sh` reports `merge-result TASK PR_URL merged|refused|unknown`.
Missing adapters, undeclared resources, denied claims, stale fences, and offline central reads print warnings in shadow mode and refuse the checkpoint in enforced mode.
The worker must run `pre-push` before a direct push or a no-mistakes pipeline that pushes on its behalf, and must run `pre-ci` before its CI request.
The coordinator does not alter repository workflow triggers or GitHub settings.

Use `FM_HOME=/path/to/home python3 bin/fm-coord-adapter.py replay` to retry a participant's locally journaled requests after an outage; it submits and claims only tasks whose dispatch is still pending and resumes checkpoints only for tasks that already hold a claim, so refused or finished tasks never reclaim resources, and `FM_HOME=/path/to/home python3 bin/fm-coord-adapter.py view` for the central projection plus local pending requests.
Each request is written to the home-local journal named in [configuration](configuration.md) before it is sent with a stable UUID; a lost reply reuses that UUID and receives the stored central receipt.
The file is serialized with a home-local lock and replaced atomically; a checkpoint that cannot take the lock within five seconds warns and skips.
An offline request remains pending and is never represented as a confirmed claim.
A refused claim or amendment is dropped from the journal, so the next checkpoint retries it with a new request ID.
A task whose declaration changes before any central submission is rerecorded with the new declaration.
When the coordinator reports an expired session generation, the adapter starts a fresh session and resets every local task to a new intent, which is submitted and claimed at that task's next dispatch or worker checkpoint; a claim that is no longer active resets that task the same way.
Claim scope is task state, not request-cache state: the replacement intent submits the brief's resources plus every path a granted amendment added plus every path the recorded worktree has changed against `origin/<base>`, so a replacement claim is never narrower than the work in flight. A pending submit reuses its journaled scope; `release` ends the attempt and drops the amended paths and recorded worktree.
Stale `publish-head` requests are resent only by `pre-push` or `replay` in head order, so the published head chain stays consistent.
A head already published for the intent, such as after a reset to an earlier commit, is not republished; `pre-push` warns and the next new head chains from the latest central head.

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
Recovery revokes all active claims, advances participant generations beyond the marker's recorded high-water generations, advances the event sequence, every allocation counter, and every slot generation past its recorded high-water mark plus a gap of ten, refuses every recorded CI batch ID, drops queued CI heads whose batch the marker records as authorized after the backup so they are never promoted again, invalidates preparation slots, retains uncertain forge attempts as `outcome-unknown`, and creates a new authority identity and marker.
Re-enroll participant sessions with new request IDs, replay the outbox by stable event ID, reconcile each unknown forge outcome against its exact PR and head, and re-admit intents before enabling integration.
If the marker is missing or the restored database's authority identity differs, stop and investigate the backup lineage rather than creating a second live authority.
