# Elastic task workers

This document owns the queue, assignment, lifecycle, cost, recovery, release-proof, provider-adapter, and operator contract for general elastic workers.
[`bin/fm-worker-lifecycle.sh`](../bin/fm-worker-lifecycle.sh) owns command mechanics, and [`bin/fm-azure-worker-provider.py`](../bin/fm-azure-worker-provider.py) is the Azure adapter.
The private foundation and one-shot command substrate remain owned by [Azure pilot deployment](azure-pilot.md) and [Disposable Azure command runner](azure-runner.md).

## Boundary and topology

A general worker VM runs one task-scoped crewmate plus the minimal machine supervisor required for lifecycle, event delivery, steering, and recovery.
It never runs Firstmate, a secondmate, another supervisor, a nested team, a browser profile, validation, policy review, or a child-worker launcher.
Persistent secondmates remain on trusted control-plane capacity and may request one task worker without moving into it.
The primary Firstmate requests workers for tasks with no matching secondmate.
Validation, review, browser, and networkless verification use their separate single-purpose compartments.

The controller is provider-neutral at the queue and state-machine boundary.
A provider adapter receives one bounded canonical JSON request on standard input and returns one bounded canonical JSON response on standard output.
The default adapter reconciles Azure through the installed Azure CLI and the landed singleton worker deployment in `bin/fm-azure-pilot.sh`.
An alternate provider must preserve the same exact identities, classifications, mutation fencing, and refusal behavior rather than translating them into best-effort names.

This implementation does not change Herdr lifecycle behavior.
The Azure adapter installs the exact committed `bin/fm-worker-supervisor.py` bytes through the named immutable `bootstrap` Managed Run Command, verifies their SHA-256 digest, and exposes only one bounded `execute` protocol plus digest-only `steer`.
The supervisor runs one argv without a shell, under exact task/home/account/worktree/repository/cloud environment bindings, emits one digest-bound bounded result, and has no Firstmate, secondmate, browser, nested-team, public endpoint, or child-worker API.
The controller never treats VM allocation or bootstrap alone as a successful task result.

No Azure apply or billable acceptance is authorized by this document.
The first live reconcile remains blocked until the corrected private foundation, this implementation, private data-plane reachability, fresh actual and forecast telemetry, exact subscription, and all live read-only inventories are independently accepted and the operator explicitly authorizes billable reconciliation.

## Queue request

`request` adds one exact task generation to the durable queue under `$FM_HOME/state/azure-workers/controller.json`.
The state file and lock are owner-only, atomically replaced, directory-synced, and bound to the canonical home, subscription hash, deployment generation, cleanup owner, and naming prefix.
The caller supplies only task, task generation, owner kind, and eligibility; the controller reads the ordinary task metadata, canonical account home/task owner, exact worktree root, physical Git-directory identity, and HEAD to derive the home, provider-account, writable-worktree, repository, and repository-generation bindings.
Caller-supplied bindings are unsupported outside the hermetic test backstop.
Raw provider-account identity never appears in bounded status or Azure tags.
The account binding must be a high-entropy digest produced by the account lease owner, not a digest of a guessable profile name.
The lease owner is the controller: it derives the binding from the profile's upstream account identity (see the placement section below), never from the profile's local slot name.
The local slot name (`openai-codex-2` and the like) DOES appear in bounded status, because an operator has to be able to see which profile a task holds; it is a local label for a pool slot, not the upstream account identity, and it never reaches an Azure tag.

The host is the only OAuth refresh authority. Before a leased single-profile home is staged, `fm-spawn.sh` requires twelve hours of access-token headroom, twice the worker VM's six-hour hard shutdown window. A stale slot is withdrawn and refused instead of being copied to a guest that could reach Pi's automatic refresh path and rotate the pool's refresh token independently.

## Provider-account placement across the Pi fleet

The task metadata names the provider-account POOL this task may draw from. The cloud lane reads the canonical absolute directory in `config/azure-worker-account-home` when present and otherwise falls back to the primary Pi coding-agent home for compatibility. This lets a local Firstmate keep a separate Pi login while Azure owns a disjoint worker fleet. WHICH profile of the selected pool the placement gets is decided by the controller, because that decision has to exclude every other concurrent placement and no task-local document can see them.

Selection happens inside `command_request`, in the same lock hold and the same `save_state` that writes the queue entry, so selection and the lease are one act.
The queue entry IS the lease: the set of leased accounts is derived from the non-complete queue, never from a second ledger, so there is no state a crash can leave in which an account is held by something the queue does not show.
Selection is deterministic - the first free profile in the pool's sorted (lexicographic) name order - and replaying the same task generation reuses the same profile, because the replay path short-circuits on the existing entry before selecting anything.

The unit of exclusion is the UPSTREAM ACCOUNT, not the profile name and not the account-home path.
Eight profiles map to eight accounts today, but nothing enforces that: a re-login can point two slots at one account, and what a concurrent crewmate actually contends for - the rate limit, the ban, the session - belongs to the account.
So `account_binding` is a digest over the profile's upstream account identity (itself a SHA-256 digest of the account id, never token material), two profiles resolving to one account are ONE lease, and the duplicate-account screen below is the same screen selection already respected.

A pool holding more than one profile is projected: the controller writes the chosen profile's single-profile account home with `bin/fm-pi-account-home.py`, under its OWN state directory (`$FM_HOME/state/azure-workers/accounts/<account-binding>`, overridable with `FM_PI_ACCOUNT_HOME_ROOT`) and deliberately not the shared crosscheck roster, which belongs to the reviewer lane and must not be rewritten under a running reviewer.
The directory is keyed on the LEASE IDENTITY, never on the profile's local slot name, because the projection key and the exclusion key must be the same function of the pool. The slot name is not: re-logging one slot from one upstream account to another yields two placements with two correct, distinct bindings that would both project into one `accounts/<slot-name>` directory, and the second write would replace the credential the first placement's still-live lease points at, leaving the queue reporting two accounts while the disk held one. A second, defensive refusal also declines to project over an account home a live queue entry still names.
A home already holding exactly one profile is that single-profile home already, and is leased in place with nothing written; its credential shape is not screened there, because "is this credential still good" has one owner, `bin/fm-credential-expiry.py`.
`request` prints the leased profile and account home, and `bin/fm-spawn.sh` writes the staged account directory exactly once, from that home, after the lease exists.
The pooled `auth.json` is never staged: the payload step deliberately does not copy it, because that step runs BEFORE the lease is created and while the tracking monitor pane is already polling, so a crash there would otherwise leave every signed-in account in a directory the monitor is willing to dispatch as `--account-dir`. The window is removed rather than guarded.
As defence in depth at the point of USE, `bin/fm-spawn-cloud-monitor.sh` re-checks that the staged account directory holds exactly one provider slot before it dispatches, and does so BEFORE taking the shared exactly-once dispatch marker so a not-yet-narrowed directory simply retries on the next poll instead of wedging both owners.
Staging the pool would put every signed-in account on the guest and let Pi resolve the first slot, which is a shared-account placement whatever the queue records.

Every failure refuses by name and none of them falls through to a shared or arbitrary profile: an unreadable or empty pool, a pool whose profiles are all unprojectable, a home naming no upstream account, and an exhausted pool (which names each leased profile and the task holding it).
Bounded status projects the live placements - profile, task generation, status, and account home - from `controller.json` alone.

**The pool is now a concurrency ceiling, and it is lower than the worker ceiling.** Concurrent placements are bounded by `min(FM_AZURE_WORKER_MAX, distinct upstream accounts in the pool)`: with the fleet's eight Pi accounts, the ninth concurrent placement refuses even though `MAX_WORKERS` is 16 and quota, budget and capacity would all admit it.
That is the requirement, not a regression - sixteen crewmates never could run on eight accounts without sharing one, they just used to do it silently - but it does halve the effective author parallelism, and compartments compete in the same pool: one compartment plus its four children consumes five of the eight before an ordinary crewmate is placed.
Raising the ceiling means adding signed-in profiles on distinct upstream accounts to the pool, not raising a knob here.
A compartment child contends in the same document as an ordinary crewmate, because `FM_HOME` still names the primary's controller for both, so the two can never be handed one account.

The controller rejects duplicate active account or writable-worktree bindings.
A general request has role `author`, is explicitly eligible, and is owned by either the primary or a secondmate; a secondmate-owned author request may carry a parent compartment pair, which marks it as a compartment child and arms the child bounds.
A `secondmate` role request stands up a secondmate compartment, is requested only by the primary, and is capped by `FM_AZURE_SECONDMATE_MAX`.
A compartment cannot mint that parent pair itself: its agent only emits a bounded `fm.secondmate-child-request/v1` on the outbox, and the compartment monitor validates it locally and then stamps the pair onto an ordinary `bin/fm-spawn.sh` spawn run as the secondmate, so every compartment child is admitted by the one controller under the child bounds.
Validation is closed and fails into a delivered answer: the exact field set the session runner emits, a recomputed self digest, the parent identity triple equal to that compartment's current task, generation, and assignment, `child_kind` in `ship`/`scout`, and a bounded brief; any failure writes a durable refusal record AND delivers a refusal into the compartment's own inbox naming the failed check, so an invalid request never reaches the request command and a resend of the same intent refuses again as a duplicate rather than being retried hopefully.
Admission refusals from the controller (fan-out, lifetime total, parent liveness, depth) round-trip into that same inbox as the spawn's own refusal text, with no queue item created.
Nothing about the child's home, account, worktree, harness, SKU, project, or repository is expressible from the cloud side; the project is local policy (`FM_SECONDMATE_CHILD_PROJECT`, persisted into the compartment environment at spawn time because the monitor pane runs in a closed environment, else that home's single project), the harness is named explicitly as the cloud lane's only runtime rather than resolved implicitly (a home carrying `config/crew-dispatch.json` refuses an implicitly-resolved crewmate harness), and the money authority remains one document because `FM_HOME` never moves for the spawn: the spawn runs under the primary's `FM_HOME` and is handed the secondmate's home as `FM_SPAWN_TASK_HOME`, which becomes the task's `state`/`data`/`projects` and travels to the controller as `--task-home`.
Acceptance is proven by the queue, never by the spawn's exit code: a zero exit is followed by reading the controller back and requiring the child's own entry carrying that compartment's parent pair, and anything else refuses loudly.
`FM_HOME` used to conflate three separable jobs - where the requesting task's local authorities live, the identity stamped into the request's `home_binding`, and the identity of the money document - and the compartment child is the first case where they differ; `--task-home` splits the first two off, and `FM_HOME` keeps only the third, so the home fence on `controller.json` is never weakened.
`--task-home` is refused outside a complete parent pair with `--role author` and `--owner-kind secondmate` ("task home is owned by compartment child requests only"), and is then authorized inside the same lock hold that inserts, immediately before the child bounds: the directory's own `.fm-secondmate-home` marker must be a regular non-symlink file naming the parent compartment, the primary's `data/secondmates.md` must map that secondmate to exactly that resolved directory, and the unchanged `enforce_child_bounds` must then find that secondmate as an assigned `role=secondmate` entry in this controller's document.
Nothing in that chain is self-authorizing: a directory that plants its own marker fails the registry link, a registry entry naming an unmarked or symlink-marked home fails the marker link, and a marked and registered home whose secondmate is not a live compartment here fails the bounds.
The registry link reads `data/secondmates.md` through the CANONICAL reader (`bin/fm-account-routing-lib.sh`'s `fm_secondmate_registry_query`), never a second parser of the same line shape, so the money path refuses everything every shell consumer refuses - a malformed line anywhere, a relative or `..`-bearing home, a home reached through a symlinked path component, a duplicate id or a duplicate home - rather than being the one reader that keeps authorizing from a registry the rest of the fleet has already rejected.
The marker link applies the same home rules `validate_secondmate_home` does (never the active firstmate home, never nested with it in either direction, never the firstmate repository, and a real home carrying `AGENTS.md` and `bin/`), and compares the marker's contents stripping trailing newlines only, exactly as the shell readers' `$(cat ...)` does.
The task home is DURABLE on the queue item and the worker record, because the release lane needs the path and not only the digest: `authority-receipt` and the surrender pre-check run `bin/fm-worker-authority.py` against the task's own home, fenced on the recorded `home_binding` so a hand-edited path cannot redirect them. Without that an admitted compartment child would hold a live worker slot with no ordinary exit, and its architectural `WORKER AUTHORITY REFUSED` would read as a genuine refusal and qualify it for surrender from the moment it was assigned.
The task home also decides WHERE the spawn stages the plaintext provider credential (`<task home>/state/<id>.cloud-account/auth.json`), so it decides where every remover has to look. Removers never infer that home from the task id, because ids are home-scoped and the same id can be live in two homes at once, so an id-keyed redirect would delete one home's live state while leaving the other's credential behind. Each remover is handed the state directory of the home whose task it is: the spawn's own rollback and re-spawn sweep pass the directory they just staged into, teardown passes its own task's home (and each secondmate home's own state directory when it reaps that home's children), and `withdraw`/`surrender`, which necessarily run with `FM_HOME` on the primary, are told by the CONTROLLER. The authorized task home is durable on the queue item and the worker record, and both commands write it to the file named by `--task-home-out`: a channel with one writer and one reader, never a line inside their output, because a value carried on a shared stream depends on stderr never being folded in and on no identifier ever containing a space or a newline. The reader follows that path only when it is absolute, traversal-free, its own physical path, and carries an `.fm-secondmate-home` marker naming the parent compartment, which is exactly what the spawn required of `FM_SPAWN_TASK_HOME`; anything else falls back to the controller's own state directory, leaving a credential to be found rather than removing state in a home the task does not live in. After the removal, the surviving-credential check inspects the home the controller named and the controller's own state directory, never the directory the removal happened to resolve, because a check whose subject comes from the thing it audits cannot fail when that thing is wrong. The per-task cloud file set itself is enumerated once, in `bin/fm-cloud-state-lib.sh`, and every remover removes that whole set, so a file added to the set cannot be created by one lane and removed by none.
The monitor deliberately sets no `FM_AZURE_WORKER_STATE_DIR` pin for the child spawn: that name is persisted into the child's durable cloud environment, so a pin would outlive the spawn and misdirect every later execute and release.
The `bounded` in the compartment invariant is per message, not aggregate: each request is size-capped and each refusal is one durable record plus one delivered envelope, but a compartment that emits many requests accumulates many refusal records and many relayed envelopes, so an operator watching a noisy compartment is watching disk and one model turn per message, not a fixed total.
`release` refuses atomically, under the controller lock, while any non-complete child still names the releasing parent; the children-quiesced check lives in `command_release` because the authority tool reads controller state lock-free.
Bounded status additionally projects every live compartment - task, status, slot, active and lifetime children counts, and the durable assignment TTL anchor - from `controller.json` fields only, never from the leg state the compartment monitor owns locally.
The same task generation and exact identity is idempotent, while a changed identity under the same task generation refuses.
An assigned request stays in the queue until its ordinary release proof is accepted and every exact cloud resource is safely reset.
A request that never reached assignment leaves the queue by `withdraw`: it accepts an entry still in `queued`, refuses anything a worker owns or a pending provider action names, requires `--confirm-withdraw` and `--confirm-subscription`, touches no capacity, and removes the per-task cloud state including the staged provider credential.
Release remains the only exit for work that ever held capacity.
Operator surrender is not a second exit: it mints that release proof for the one case where the ordinary authorities are unrecoverable, under its own refusal-first gates (below).
Therefore a truly empty queue also means there is no active task worker and desired worker compute is zero.

```sh
bin/fm-worker-lifecycle.sh request \
  --task '<task-id>' \
  --task-generation '<task-generation>' \
  --owner-kind primary \
  --eligible
```

Use `--required` only for non-discretionary recovery or landing work already authorized by ordinary Firstmate ownership.
It does not bypass unreadable cost or quota evidence, identity checks, the sixteen-worker cap, or release protection.

## Desired capacity and admission

The same durable allocator also owns specialized reservations through `capacity-reserve`, `capacity-reserve-shape`, `capacity-release`, and the cleanup-only `capacity-retire-fence` barrier.
Every caller uses the canonical Firstmate control home and its one shared state directory; `FM_AZURE_SHARED_CAPACITY_STATE_DIR` may relocate that directory only for an explicitly configured installation and must be identical for all callers.
A validation, review, browser, networkless-verifier, or Crosscheck caller submits one exact reservation ID and fence binding, a reviewed SKU/family pair, the reviewed four-vCPU worker shape or reviewed eight-vCPU control shape, and finite worst-case cost before creating compute.
Admission returns `reserved` or leaves the request durably `queued`; callers must not create compute for a queued reservation.
A consumer that needs a complete multi-machine specialized shape, such as one eight-vCPU control cell plus eight four-vCPU shards, reserves it atomically through `capacity-reserve-shape` with every exact constituent reservation ID, workload role, SKU, family, vCPU count, and cost named in one call.
Initial shape admission is always discretionary and every constituent remains subject to cumulative actual and forecast cost admission.
Shape admission is all-or-nothing under one lock and one inventory read: if any constituent fails regional, exact-family, specialized-envelope, or budget admission, no new constituent is reserved and the complete shape stays durably queued with the exact refusal.
A shape retry never demotes constituents that are already reserved, and each constituent then behaves as one ordinary shared reservation: a child runner re-admits the same reservation ID idempotently to prove lineage without double-counting, and `capacity-release` frees each constituent only with its exact fence and zero-compute cleanup receipt.
The complete shape total may never exceed the shared 40-vCPU specialized envelope, and no shape or constituent bypasses cumulative actual/forecast admission in commissioning mode.
The existing disposable runner invokes this path before its Azure management reservation and VM creation, then releases the shared reservation only after exact VM/NIC/OS-disk absence.
Restarting either controller is idempotent under the same reservation ID and fence, while a changed identity refuses.
An exact failed-retained validation purge closes its capacity fence only after every sealed constituent is released and provider-inactive. `capacity-retire-fence` repeats the complete same-fence ledger and provider census while holding the allocator lock, then durably records a permanent retirement tombstone before unlocking. Both single and shape reservation entry points refuse a retired fence before any insertion or re-admission, so retained disks, private storage, and RBAC can be deleted only after no later same-fence capacity can enter. The lifecycle state advances to v2 when this authority is first written, causing an older allocator that does not understand fence retirement to refuse the document rather than reopen it.

The controller computes desired active capacity from all eligible queued and assigned work, current exact assignments, the sixteen-worker software cap, one shared East US regional ceiling, live exact-family quota, actual and forecast spend, and durable per-assignment cost reservations.
Quota is only capacity and never creates demand.
The reviewed shared ceiling is 128 regional vCPUs, with zero VM vCPUs used at the latest foundation evidence boundary.
The author plan uses 64 vCPUs across sixteen 4-vCPU workers drawn from eight unrestricted families whose reviewed allowance is 10 vCPUs each.
The same 128-vCPU ceiling reserves the existing 40-vCPU specialized validation shape plus 22 vCPUs of shared landing, replacement, recovery, browser, and control-plane headroom.
A future 2-vCPU supervisor is ordinary observed regional usage, so 64 author + 40 specialized + 22 shared headroom + 2 supervisor equals the 128-vCPU ceiling.
Active specialized VMs and their durable pending runner reservations consume the same 40-vCPU specialized shape instead of being counted against a fictional separate quota, while any unused part stays reserved for queued specialized demand.
For the region and every exact family, admission uses `max(Azure observed usage, exact active fleet vCPUs) + exact reservations without active compute + candidate`; this closes both Azure telemetry lag and duplicate active/reserved counting.
An active specialized VM without one exact reservation, a reservation with foreign ownership, a duplicate invocation, an unknown SKU/family, or unreadable family usage/limit fails the shared inventory closed.
Unrelated or control-plane VM usage is also included by Azure's regional usage value.
Combined author and specialized demand beyond the shared 128-vCPU ceiling remains queued, as does demand beyond budget.
The live 10-vCPU Dav6 family limit admits only its two reviewed author slots and is not treated as a requirement for homogeneous Dav6=96 capacity.
Every later mixed-family slot proves its own exact current family allowance.
No capacity reservation creates an always-on worker pool, and queue-empty still drives general worker compute to zero.

Commissioning uses 3,500 aggregate author worker-hours and $1,000 as planning and warning thresholds; shared actual/forecast cost admission covers all workloads regardless of that author-hour counter.
The thresholds do not terminate work or erase demand.
New discretionary author and specialized launches stop before the greater of actual or forecast spend plus all durable author and specialized reservations and the candidate reservation reaches $1,500.
An author reservation uses the selected SKU's live retail rate, the configurable expected author interval, and a conservative retained-disk/control allowance.
A specialized reservation uses the runner's exact finite 24-hour itemized maximum.
The runner's commissioning path no longer bypasses cumulative actual or forecast admission; its exact `$1,500` Azure Budget remains a prerequisite and the allocator additionally requires readable shared Cost Management actual and forecast values.
Cost Management, family quota, regional quota, and retail rates must all be readable before a new launch.
Actual and forecast cost queries cover the complete shared resource group, including author, validation, review, browser, recovery, networking, storage, and monitoring spend rather than granting specialized work a separate budget.
Lagging billing telemetry cannot admit concurrent work twice because both local author assignments and disposable-runner management reservations are merged into the same actual/forecast admission pressure.
Provider reservations are cross-checked against any local reservation with the same ID; conflicting SKU, family, vCPU, or amount bindings refuse rather than double-count or guess.

After stabilization, set `FM_AZURE_WORKER_POLICY_PHASE=steady` and tune `FM_AZURE_WORKER_STEADY_TARGET_USD` toward $1,000.
That changes the admission limit without changing resource identity or lifecycle design.
The commissioning ceiling must remain exactly $1,500.
Budget pressure never deallocates, deletes, duplicates, or terminates active or unlanded work.
During commissioning only, when the fresh resource group's Cost Management forecast model reports the exact insufficient-training-data refusal while actual spend is readable, the operator may set `FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST=1` so the readable actual substitutes as the conservative forecast; any other unreadable cost telemetry still refuses admission.
It blocks new discretionary author and specialized capacity and allows only ordinary idle cleanup.

A separate DAILY spend bound sits on top of the cumulative limits: once the day's recorded spend reaches `FM_AZURE_WORKER_DAILY_BOUND_USD` (default 100; an explicit zero, negative, or non-numeric value refuses loudly rather than meaning unbounded), every lane that commits new money refuses with the exact day, spend, and bound: the compute-creating and compute-resuming provider actions (`create`, `resume`) AND new specialized reservation admissions (`capacity-reserve`, `capacity-reserve-shape`), because the disposable runner reserves automatically and an ungated reserve lane could quietly burn past the bound with no human anywhere.
Cost Management reports only month-to-date actual, so day spend is computed honestly as current actual minus a durable `daily_cost_baseline` snapshotted under the fleet lock on the first observation of each new UTC day; an unreadable actual fails the bound closed.
The bound is a backstop on RECORDED spend - the actual lags hours - so the real same-day protectors remain the per-mutation cumulative admission and the idle deallocate path below; the bound guarantees a day cannot keep admitting new compute after the recorded number crosses it.
Wind-down is never blocked: releases, `capacity-release`, deallocates, compute deletions, resets, and the claim-exempt message lane stay allowed while the bound is tripped; `execute` on an already-assigned worker stays allowed because that capacity is already held and billing, and for the same reason a lineage re-admission of an already-reserved shape constituent is already-held accounting and skips the gate.
The only way past a tripped bound is the explicit operator override `FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE=<utc-day>` naming the exact current UTC day; it admits for that day only, is printed loudly by reconcile and resume, is carried on the admitted action and reserve output, and is recorded durably in `daily_bound_override_used` - only after the admission decision actually went the override's way - and shown in status.

Example specialized reservation flow (the disposable runner performs this automatically):

```sh
bin/fm-worker-lifecycle.sh capacity-reserve \
  --reservation-id '<invocation-id>' \
  --fence-binding '<64-lowercase-hex>' \
  --role validation \
  --sku Standard_D4as_v7 \
  --sku-family StandardDasv7Family \
  --vcpus 4 \
  --amount-usd '<finite-worst-case-cost>' \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"

bin/fm-worker-lifecycle.sh capacity-release \
  --reservation-id '<invocation-id>' \
  --fence-binding '<same-64-lowercase-hex>' \
  --cleanup-receipt '<64-lowercase-hex-zero-compute-proof>' \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

`capacity-release` never deletes cloud state.
It records that the specialized owner has already proved exact compute absence; ambiguity leaves the reservation consuming capacity and budget.

## Assignment and isolation

A new assignment chooses one free reviewed slot and durably records its assignment generation before the provider mutation.
The singleton pilot create also receives and re-verifies a canonical shared-admission digest over slot, SKU/family, assignment generation, and cost reservation, so it cannot be invoked as a separate allocator path.
The provider creates or claims one VM generation, one slot user-assigned identity, one provider-account disk, one task/worktree disk, one exact container role, and one private state container.
The complete assignment identity also includes the Azure Monitor extension, named `bootstrap` and `execute` Managed Run Commands, enabled VM-targeted TTL schedule with deadline, zero-RBAC global reservation blob, private request blob, and private result blob.
All fifteen resource kinds are recorded by complete resource ID and immutable provider identity or ETag; missing or extra Run Commands, a disabled/retargeted TTL, absent staging/result digest, or ambiguous reservation refuses the assignment.
Every taggable resource is additionally bound to deployment owner, slot, home, task, task generation, assignment generation, cloud generation, account digest, worktree digest, repository digest, and repository generation.
The container carries the equivalent exact metadata.

No two active tasks share a VM, account lease, browser profile, or writable task disk.
The worker has exactly one slot identity and its NIC has no public-IP relation.
The general worker contract forbids a browser profile rather than allocating one.
The OS disk is disposable, while the account and task disks detach from VM deletion and remain encrypted by the guest contract.
Provider-account credentials never enter ARM parameters, controller output, logs, tags, images, browser state, or the control home.

A submitted provider action has a canonical SHA-256 idempotency key and remains in the per-slot `pending_actions` map until the exact provider result is durably applied; the map entry is a deep copy that re-derives its own key at every load, and the legacy scalar slot permanently holds a sentinel an old binary refuses rather than misreads.
After a host restart, the same action and key are replayed.
The compartment message lane (`message-put`/`message-collect`) is the one provider operation family outside the per-slot claim contract: bounded, content-addressed, idempotent data-plane blob transfers that touch no compute, no money, and no lifecycle state; every compute-mutating action keeps the full claim/lease/fence discipline.
Child results return over that same lane: a compartment asks with a closed `fm.secondmate-attach-request/v1` carrying no selector at all, only a bounded monotone `attach_sequence` (1 to 32, strictly past what has been served) that distinguishes one ask from the next because the rest of the payload is constant for an assignment, and the monitor bundles the commits its secondmate home worktree gained over the compartment's dispatched repository generation, uploads them as `session/in/attach/<sha256>.bundle`, and announces name, digest, and byte count in an inbox message the guest's fetch checks size-first.
That delta is the home repository's, which is the compartment's own repository, and deliberately not the child's code: a crewmate commits into a worktree of its project repository, whose history shares no ancestor with the home repository the compartment holds, so a project bundle could not fast-forward there even if it were shipped, and what actually returns is the child's report and other home artifacts.
An ask that finds no delta serves nothing, records no acceptance, and burns no `attach_sequence`.
The announcement is built from the upload receipt only when that receipt's digest and byte count both equal the bundle the monitor hashed locally, so a mismatched announcement is never sent; a child's terminal status is mirrored into the same inbox once, taking `complete` from the controller queue and the complete-versus-failed split from the child's own recorded execution result.
The Azure singleton deployment is incremental and receives the same task, home, assignment, and snapshot bindings, so replay converges one generation rather than creating a second assignment.
A visible VM with another task or assignment binding refuses instead of being adopted.

## Outcome collection and landing

A crewmate on a worker holds no forge or provider credential, so the work comes home as bytes, not as a push: nothing on the worker pushes anywhere, and the local side keeps the landing authority.
`execute --outcome-dir` records `outcome_expected` inside the digest-bound execution request and the provider mints one short-lived user-delegation SAS with create/write on exactly one blob name, delivered as a protected Run Command parameter.
That SAS scopes the credential, not the guest: the worker identity already holds Storage Blob Data Contributor on its whole state container, so what makes a landing safe is the digest in the signed result, not the narrowness of the SAS.
Because the expectation is digest-bound, a stripped parameter cannot silently downgrade a landing task: the guest refuses before the argv runs.

After the bounded execute, the supervisor counts the commits the crewmate added over the bound repository generation, bundles exactly those commits, refuses a bundle over 256 MiB, uploads it, and records `outcome_present`, `outcome_commits`, `outcome_sha256`, `outcome_bytes`, and `outcome_error` inside the signed result.
A collection failure never aborts the result: the command has already had its effects, so the failure is recorded instead, which both blocks an unverifiable landing and stops a replay from running the command a second time.
A worker whose pinned supervisor predates this contract answers with no outcome disposition at all, and the controller refuses that result rather than reporting a task whose commits silently never came home.

The controller downloads the blob only after the digest-bound result commits to its bytes, verifies size and SHA-256, and stores it in the requesting task's outcome directory.
The tracking monitor then fast-forwards the leased local worktree, but only when that worktree still sits on the dispatched generation and is clean; otherwise the verified bundle is kept and its path reported.
Landing authority, push, and release receipts stay exactly where the ordinary local flow already puts them.
The blob name carries the request digest, so a later execute against the same worker cannot overwrite an outcome the controller has not collected yet. Reset deletes the inbound staging archives by name and the outcome blobs as part of removing the whole state container.

## Release, reset, and cooldown

The controller never infers safe deletion from a terminal chat line, a missing VM, elapsed time, or budget pressure.
The ordinary Firstmate owners first remove the endpoint, publish the report, prove landed work, release the provider account, and complete their normal cleanup checks.
`authority-receipt` invokes `bin/fm-worker-authority.py`, which reads the ordinary task metadata, endpoint backend oracle, completion-report contract, Git landing graph, account task/home binding, and clean exact worktree root rather than accepting operator-entered digests.
For Azure placement, the task's `account_home` is the vendor-neutral Pi pool selected above, so account authority instead requires the task-recorded selected profile and single-profile home to equal the controller queue's exact lease, then reads its owner-private credential without following links and reproduces the controller-owned upstream-account binding.
It produces an `fm.worker-release/v2` bundle with five independently canonical `fm.worker-authority/v1` receipts for endpoint absence, report validity, landed work, account ownership, and writable-worktree cleanliness, plus the exact home, task, generations, cloud instance, account, worktree, repository, and every resource identity.
When the CONTROLLER-OWNED worker role is `secondmate`, the same five receipts carry compartment evidence semantics: endpoint proves the compartment monitor pane absent through the same backend oracle; report proves the session closeout - the monitor's terminal status file, the chained close ack in its durable state, and the ordered `completion.md` contract; landing proves every chained outbox bundle landed into the local secondmate home worktree (or provably none) by REACHABILITY - each collected bundle's own tip commit must be an ancestor of the home worktree's HEAD, which also descends from the assignment's exact starting repository generation; account is unchanged; and worktree proves the home quiesced - exact repository root, no uncommitted or untracked work - while staying advisory for children, whose refusal `command_release` owns.
Which semantics apply is never decided by the task metadata alone: the worker record's `role` and the metadata's `kind` must agree, and a disagreement in either direction refuses, so flipping one local metadata line can never move an ordinary author worker onto the compartment lane and release work that was never landed.
The compartment landing proof re-derives the collected outbox chain BY CONTENT rather than counting filenames, because the mailbox and the durable monitor state share one local directory and are both inside an attacker's write set: each entry's name digest must equal the SHA-256 of its canonical unsigned body, its sequence must match its name, each `chain_digest` must extend the previous entry, and the recomputed chain must reproduce the verified tip.
That tip is the anchor, and it comes only from the controller document: `compartment-chain-tip` records it on the worker record under the controller lock, monotonically (a rewind, or the same sequence with a different digest, refuses), and the release authority reads it from there.
A chain anchored at a public genesis constant and terminated by a tip the attacker can also write proves nothing, so monitor-local state may never supply it: an absent controller-owned tip REFUSES, naming `surrender` as the sanctioned exit, rather than falling back.
The compartment monitor records those tips, so the ordinary release authority is the normal exit and `surrender` is the degraded one.
`bin/fm-secondmate-cloud-monitor.py process-mailbox` calls `compartment-chain-tip` on every pass whose verification ADVANCES the tip, with the sequence and `chain_digest` it just proved, and remembers the recorded pair in its durable state so an unchanged tip is skipped rather than replayed each poll.
The call is made strictly after the local proof, because the command attests without verifying; it is its own lifecycle verb and never rides the claim-exempt message lane, whose invariant is that `message-put`/`message-collect` write no lifecycle state.
A refusal is classified, not swallowed: a monotonicity refusal (a rewind, or the same sequence carrying a different digest) means the controller record and the monitor's own proof disagree about the chain, so it freezes the lane through the same sticky `.chain-break` marker.
An already-released refusal is end-of-life but is never taken at face value, because `command_compartment_chain_tip` checks the release proof BEFORE its monotonicity block: a released worker answers a genuine rewind or fork with the released string, so the monitor reads the held tip back out of the controller document, freezing on a contradiction, falling to the retry class when the document cannot be read, and closing the lane only when the held tip cannot contradict this chain.
That read-back is deliberately STRICTLY STRONGER than the controller's own rule, because the read-back exists precisely to cover a rule the controller applies too late: monotonicity alone never contradicts a held tip strictly BELOW the proved sequence, so a longer forged chain that diverges beneath it would close benignly and relay, and the proved chain must therefore also REPRODUCE the held tip's digest at the held tip's own sequence - the identical check `secondmate_verified_chain` already performs before it will prove landing.
Repairing that ordering inside the controller (running monotonicity before the release gate, so a fork refuses as a fork whatever the worker's phase) is a follow-up owned by `bin/fm-worker-lifecycle.py`, not by the monitor.
Every other refusal is about current worker ownership, changes between passes by design (a re-spawn mints a new assignment generation; `resume` preserves it and bumps `cloud_generation`), and warns in the pane and retries under exponential backoff, because every attempt takes the controller lock.
A compartment whose monitor never ran, or whose tip lane was frozen or closed before a tip landed, still exits through `surrender`.
The attestation is write-once-per-advance from an attacker-writable file, so that file can SUPPRESS attestation even though it cannot forge one: planting `chain_tip_closed`, or a `recorded_chain_tip` equal to the tip about to be proved, silently downgrades that compartment to `surrender` for good.
The monitor's `landed_bundles` record is ADVISORY and never decides the receipt: it is one more field in the same attacker-writable file, so landing is settled by whether the bundle's commits are actually reachable in the home, and a declared bundle whose collected file is gone refuses because nothing then names the commits it carried.
`compartment-chain-tip` is an unverified ATTESTATION: it never reads the mailbox, so its whole value is caller trust, and there is no privilege separation between a caller who can write under `state/` and one who can execute `bin/fm-worker-lifecycle.sh`.
A mailbox holding fewer entries than the monitor recorded as delivered, an absent or redirected mailbox, and a recorded chain break (including a dangling marker symlink) all refuse rather than reading as "provably none" - which is about BUNDLES, and is proved only by a verified chain whose leg summaries declare nothing.
The compartment report receipt adds a stricter section check on top of the shared completion-report authority, which stays verbatim for the ordinary lane: each contract heading must open its own line outside any code fence and carry content.
The compartment bundle is the identical `fm.worker-release/v2` shape and verifies through the unmodified `verify_release_against_worker`.
`proof-template` remains diagnostic only: its placeholders are deliberately invalid and hand-filling them is unsupported.
A missing, stale, malformed, or conflicting receipt retains everything.

After an exact release receipt, reconcile deallocates the VM promptly.
Azure deallocation stops compute billing but not disks, NICs, public foundation meters, monitoring, or storage operations.
After deallocation it deletes the named execute and bootstrap Run Commands and monitor extension before the VM, then proves VM absence and disk/NIC detach before deleting NIC and OS disk; the TTL remains enabled until those proofs complete and is deleted last among compute children.
Reset then conditionally deletes the result, request, global reservation, released account disk, task disk, identity, role, and container.
The default cooldown is 300 seconds and may be configured from zero through 1,800 seconds.
The default and currently required warm-idle target is zero.
A release-proved worker whose VM is already dark but whose `cooldown_started_at` is null - the operator-side deallocate that surrender's dark-compute gate requires never stamps the field - gets the stamp durably on the planner's first observation, so the cooldown clock starts instead of restarting forever and `delete-compute` becomes due.

An ASSIGNED worker whose task provably ended is not left billing until its TTL fires: when its newest durable activity stamp - the last recorded execution AND the last recorded steer both count as recency - is more than `FM_AZURE_WORKER_IDLE_RELEASE_SECONDS` old (default 14,400 - the four hours wkr-04 idled - floor 600), its queue item is still `assigned`, no pending provider action claims the slot, and the VM is still running, reconcile plans an automatic DEALLOCATE.
Idle deallocation is deliberately NOT a release or reset: releasing requires authority receipts a machine cannot mint, while deallocation is reversible at the VM level and stops the compute spend, which is what the cost guard needs.
The boundary is: idle-deallocate stops compute cost unattended; the ordinary release stays human-driven.
Be honest about what it means for the assignment: an idle-deallocated ASSIGNED worker is operationally terminal for that assignment - `execute` cannot run on deallocated compute, `resume` requires the VM to be absent, and no power-on lane exists - so release (or surrender) is the exit.
Compartment operators whose workers must legitimately outlive the default must raise `FM_AZURE_WORKER_IDLE_RELEASE_SECONDS`; in particular the pending secondmate monitor renews legs at 14,400 seconds, exactly the default threshold, so a deployment relying on renewal-at-threshold races the deallocate and must run with the knob above its renewal cadence.
Status output loudly lists every idle-deallocated worker still awaiting its proper release, and the ordinary authority-receipt/release (or surrender) flow then proceeds exactly as for any dark worker.
A worker with no recorded execution at all is never idle-deallocated - nothing in controller state proves its task ended - and its per-VM TTL schedule remains the backstop.

When compatible queued work exists, reconcile may skip the idle wait after deallocation, but it still deletes disposable compute and completes the exact released reset first.
The next assignment receives a new assignment generation, a new cloud VM/NIC/OS generation, a new user-assigned identity, a new provider-account disk, a new task disk, and a new container binding.
Warm reuse never passes a prior task's filesystem, process, credential, browser state, socket, secret-bearing cache, cloud identity, or provider lease directly to the next task.

Reset deletion uses exact IDs, immutable identities, tags or metadata, detach relations, and provider ETags where supported.
A replacement, unreadable relation, foreign tag, missing ETag, public NIC relation, or partial inventory records a bounded cleanup refusal and retains the resources.
No age or cost override can convert retained-for-investigation into safe deletion.

### Operator surrender for unrecoverable ordinary authority

`surrender` releases one exact ASSIGNED worker whose ordinary release authority can no longer be minted, for example when local teardown consumed the task metadata before any receipt existed.
Surrender is refusal-first, not a shortcut: the command runs the ordinary authority itself and refuses when that succeeds (and fails closed when the authority tool breaks rather than refuses), refuses live compute (the VM must be deallocated or stopped), refuses to replace an ordinary release proof, refuses while a pending provider action exists on that worker's slot, refuses when the controller's own execution records show repository work whose landing is unproven unless the operator passes `--confirm-discard-unlanded`, and demands an operator `--reason` plus the same explicit confirmation pair as withdraw.
The minted bundle keeps the `fm.worker-release/v2` shape the deallocate/delete-compute/reset machinery fences on, but every authority verdict is `surrendered` - `release` rejects that verdict, so a surrender bundle can never replay through the ordinary release command - and a top-level `surrender` block records the operator reason and the ordinary authority's refusal verbatim.
Surrendering a parent whose queue still holds non-complete compartment children refuses unless the operator passes `--confirm-orphan-children`; with the flag, every live child's queue entry gains a durable `reparented_to: primary` note under the same lock hold that records the surrender, the `surrender` block records the orphan count, and the captain drives those children from the local home from then on.
After the proof is recorded, reconcile owns deallocation, compute deletion, and reset exactly as for an ordinary release, and the wrapper removes the task's locally staged provider credential keyed off the command's own `FM-SURRENDERED` receipt.
If the wrapper dies between the receipt and that removal and reconcile then converges the entry to `complete`, the rerun refusal names the recovery: remove the staged credential with `fm_cloud_state_remove` from `bin/fm-cloud-state-lib.sh`.

## Recovery and reconciliation classes

Every live read classifies each controller-owned slot into exactly one operator outcome:

- `assigned` means one exact VM generation is bound to one active task generation.
- `clean-warm` means a freshly reset unassigned generation exists, although normal policy immediately drives the count toward zero.
- `deallocated` means exact released worker compute is dark inside its bounded cooldown.
- `orphaned-safe-to-delete` means the release receipt owns exact residual resources after compute removal.
- `retained-for-investigation` means identity, state, or ownership is missing, conflicting, or unlanded and nothing may be deleted or duplicated.

The Azure adapter inventories only names in the reviewed resource group and separates same-name foreign owner or generation conflicts.
It never adopts unrelated subscription resources.
The monitor extension, bootstrap/execute Run Commands, and TTL schedule use their exact ARM resource IDs as identity; Azure `provisioningState` is mutable lifecycle state, not identity.
Create, execute, and steer still require ready monitor/bootstrap children, while deallocation and exact cleanup tolerate Azure's ordinary post-deallocation state transition and retain the resource-ID, parent-VM, tag, script, and digest fences.
A missing VM with retained task or account disks is always retained-for-investigation.
It is never interpreted as a free slot and never triggers duplicate task execution.

To recover unfinished work, the operator uses `resume` with the exact task, task generation, repository binding, subscription confirmation, and explicit resume confirmation.
Resume requires the old VM, NIC, and OS disk to be absent; both exact retained disks to exist detached; every stored immutable identity and task/account/worktree binding to match; and no release receipt to exist.
It increments only the cloud generation, creates fresh VM/NIC/OS capacity, reattaches the same task-owned retained disks, and keeps the assignment generation fenced.
Any mismatch retains the slot for investigation.

`execute` accepts exact task, task generation, assignment generation, bounded wall time, explicit subscription/execute confirmations, and argv after `--`.
It uploads a canonical request privately, invokes only the named execute Run Command and pinned supervisor, verifies the returned task/assignment/cloud/repository/result digest, stores the private result identity, and replays the same result idempotently without a second execution.
`steer` accepts only a lowercase SHA-256 request digest plus exact task, task generation, assignment generation, and subscription confirmation.
The Azure adapter re-verifies the full live assignment before invoking the minimal guest supervisor with those non-secret bindings.
Its read-only inventory uses Azure CLI 2.88-compatible role-assignment syntax (`--all` without `--resource-group`), requires private Entra blob reads for reservation/request/result identities, and uses one unambiguous primary Linux on-demand USD Consumption meter while excluding Spot, Low Priority, Windows, dev/test, reservation, and savings offers.
It never forwards arbitrary shell text, provider credentials, or a hosted control endpoint.

## Reconcile and bounded status

A read-only plan is the default:

```sh
bin/fm-worker-lifecycle.sh reconcile
```

A billable or destructive convergence requires both flags and is still subject to the landed-code checks in the Azure pilot wrapper:

```sh
bin/fm-worker-lifecycle.sh reconcile \
  --apply \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

The home lock now covers only short read-validate-claim and apply sections; every provider mutation runs outside it under a non-blocking per-slot lease, so mutations for different slots run concurrently while readers and unrelated mutations proceed. Unapplied provider actions are durable per slot in `pending_actions`, every load is fenced to the lock hold that commits it, and a save whose on-disk revision moved since its load refuses instead of overwriting another writer's document.
Reconcile drains stranded claims AFTER convergence, skipping any slot whose claim a live process still owns, so a wedged or hours-long replay cannot stop the fleet.
`abandon-claim` can record and clear either an exact-key provider result whose apply deterministically refuses, including a script-bound Failed or Canceled execution disposition that names the claimed task-command resource, or an exact-key `REFUSED-IDENTITY` replay whose recorded resource identity can never bind again.
Both dispositions are recorded in `cleanup_refusals` before the claim is cleared, while an ordinary transient provider failure retains the claim unchanged.
Azure may omit `source.script` even for the freshly created async preflight stub. That shape permits its one initial submission only while both staging blobs still carry the exact assignment/pending sentinels and instance view is Failed with exit `-202` and no result marker. The execution update atomically tags the Run Command with its request digest and idempotency key; a replay bearing those tags is bound even when source remains absent. A crash after staging changes but before the tagged update stays fail-closed. Every other missing, non-string, empty, or whitespace-only source is ambiguous unless a digest-valid result proves a differently tagged prior execution completed. An exact-bound Run Command that is still Updating or Running, reports Succeeded without a digest-valid request-bound result marker, or returns a terminal disposition naming a foreign task-command resource likewise retains the claim without submitting the command again.
Each reconcile refreshes Azure before selecting the next action and stops after 64 actions even if a provider never converges.
A provider error preserves the slot's pending action and records a bounded cleanup refusal.
The next controller process replays that exact action before considering new work.

`status` is local and bounded by default, while `status --live` refreshes Azure and cost evidence.
The output includes author and specialized queue depths, desired and actual active workers, all five classification counts, assignment generations, worker-hours and warning threshold, actual and forecast spend, active policy phase and limit, the 128-vCPU regional ceiling plus observed and observed-plus-reserved usage, exact-family observed-plus-reserved commitments, the 64-vCPU author plan, active and reserved specialized capacity, 22-vCPU shared headroom, cooldown, warm target, retained-disk count, and the last ten cleanup refusals.
It omits subscription IDs, resource IDs, account identities, account digests, worktree digests, private addresses, credentials, and secrets.

## Operator policy and overrides

Supported policy changes are deliberately narrow:

- `FM_AZURE_WORKER_POLICY_PHASE=commissioning|steady` selects the $1,500 commissioning admission ceiling or the configurable steady target.
- `FM_AZURE_WORKER_STEADY_TARGET_USD` changes the post-stabilization target between $500 and $1,500.
- `FM_AZURE_WORKER_ADMISSION_HOURS` changes the one-through-168-hour reservation interval.
- `FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS` changes the zero-through-1,800-second cleanup delay.
- `FM_AZURE_WORKER_DAILY_BOUND_USD` changes the daily recorded-spend bound; unset means the default 100, and zero, negative, or non-numeric values refuse loudly instead of meaning unbounded.
- `FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE=<utc-day>` is the one explicit operator override past a tripped daily bound, valid only for the exact current UTC day, always printed and durably recorded when used.
- `FM_AZURE_WORKER_IDLE_RELEASE_SECONDS` changes the idle-deallocate threshold between 600 and 604,800 seconds (default 14,400).
- `FM_AZURE_WORKER_MAX` may lower the software cap but may never exceed sixteen.
- `--required` admits already-authorized recovery or landing demand through cost pressure, but never through unreadable telemetry, quota, identity, or cleanup proofs.

There is no force-adopt, force-delete, delete-by-age, kill-for-budget, public-network, shared-account, shared-worktree, shared-browser, warm-filesystem, or hosted-form override.
A human who needs a different destructive or security boundary must change and review this contract rather than bypass it at runtime.

## Lavish

Lavish remains a downloaded self-contained form artifact whose completed answer returns through a file.
The worker lifecycle creates no hosted form service, remote-write form, browser session, or writable interaction endpoint.
A decision that uses Lavish stays on trusted control-plane capacity and may request a general worker only after the answer file is durably collected.

## Isolated Azure acceptance

Hermetic tests exercise the complete zero-to-zero state/provider path and the pinned guest protocol without Azure mutation or cost.
Real usability remains unclaimed until the corrected reviewed foundation and this lifecycle are landed, private management and blob reads work, actual and forecast telemetry are fresh, and an operator explicitly authorizes this billable exercise.
Run `bin/fm-worker-lifecycle.sh acceptance-plan` for the concise checklist.

The complete acceptance must record all of these outcomes:

1. Start from zero and run at least three representative tasks in parallel on three distinct VMs, account bindings, and task disks.
2. Finish one task while another compatible task waits and prove that deallocate, VM/NIC/OS deletion, released account/task/identity/container reset, and a new assignment generation occur before the waiting task starts.
3. Drain every request and prove desired and active worker compute reach zero after cooldown.
4. Prove every disposable VM, NIC, OS disk, extension, Run Command, TTL, staging request/result, and active global reservation is absent, while only explicitly retained ambiguous unfinished disks remain.
5. Delete one deliberately unfinished worker VM and prove the old exact task disk survives, a normal request cannot claim its slot, and explicit exact-generation resume reattaches it to fresh VM/NIC/OS capacity.
6. Restart the controller after a submitted create, deallocate, delete, and reset and prove each idempotency key produces one transition and no duplicate assignment.
7. Force actual and separately forecast budget pressure and prove new discretionary launches stop while existing active and unlanded work remains untouched.
8. Prove every VM has no public IP or public ingress and cannot see another task's credential disk, worktree disk, browser state, process, socket, cache, provider lease, or cloud identity.
9. Execute one representative private command through the pinned supervisor, collect its exact result, close the real endpoint, validate/publish the report, prove landing, account release, and clean worktree through `authority-receipt`, then record bounded status plus actual and forecast cost evidence before, during, and after the exercise.

Every acceptance leg needs a positive control that proves the check detects the unsafe state.
Positive controls include a planted public-IP relation, a foreign immutable ID, a stale task generation, a duplicated account digest, a duplicated worktree digest, a deliberately retained dirty disk, a repeated provider action, a forecast above policy, and planted cross-task files, processes, sockets, browser data, cloud identities, or credentials.
The unsafe fixture must be isolated, must trigger the expected refusal or probe failure, and must be removed without weakening the production check.

A failed leg keeps cloud-default author use unaccepted.
It does not authorize public ingress, broad identities, shared leases, automatic local fallback, forced cleanup, or a hosted Lavish form.
