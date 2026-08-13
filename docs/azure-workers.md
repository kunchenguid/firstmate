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

The controller rejects duplicate active account or writable-worktree bindings.
A general request has role `author`, is explicitly eligible, and is owned by either the primary or a secondmate.
The same task generation and exact identity is idempotent, while a changed identity under the same task generation refuses.
An assigned request stays in the queue until its ordinary release proof is accepted and every exact cloud resource is safely reset.
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

The same durable allocator also owns specialized reservations through `capacity-reserve`, `capacity-reserve-shape`, and `capacity-release`.
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

A submitted provider action has a canonical SHA-256 idempotency key and remains in `pending_action` until the exact provider result is durably applied.
After a host restart, the same action and key are replayed.
The Azure singleton deployment is incremental and receives the same task, home, assignment, and snapshot bindings, so replay converges one generation rather than creating a second assignment.
A visible VM with another task or assignment binding refuses instead of being adopted.

## Release, reset, and cooldown

The controller never infers safe deletion from a terminal chat line, a missing VM, elapsed time, or budget pressure.
The ordinary Firstmate owners first remove the endpoint, publish the report, prove landed work, release the provider account, and complete their normal cleanup checks.
`authority-receipt` invokes `bin/fm-worker-authority.py`, which reads the ordinary task metadata, endpoint backend oracle, completion-report contract, Git landing graph, account task/home binding, and clean exact worktree root rather than accepting operator-entered digests.
It produces an `fm.worker-release/v2` bundle with five independently canonical `fm.worker-authority/v1` receipts for endpoint absence, report validity, landed work, account ownership, and writable-worktree cleanliness, plus the exact home, task, generations, cloud instance, account, worktree, repository, and every resource identity.
`proof-template` remains diagnostic only: its placeholders are deliberately invalid and hand-filling them is unsupported.
A missing, stale, malformed, or conflicting receipt retains everything.

After an exact release receipt, reconcile deallocates the VM promptly.
Azure deallocation stops compute billing but not disks, NICs, public foundation meters, monitoring, or storage operations.
After deallocation it deletes the named execute and bootstrap Run Commands and monitor extension before the VM, then proves VM absence and disk/NIC detach before deleting NIC and OS disk; the TTL remains enabled until those proofs complete and is deleted last among compute children.
Reset then conditionally deletes the result, request, global reservation, released account disk, task disk, identity, role, and container.
The default cooldown is 300 seconds and may be configured from zero through 1,800 seconds.
The default and currently required warm-idle target is zero.

When compatible queued work exists, reconcile may skip the idle wait after deallocation, but it still deletes disposable compute and completes the exact released reset first.
The next assignment receives a new assignment generation, a new cloud VM/NIC/OS generation, a new user-assigned identity, a new provider-account disk, a new task disk, and a new container binding.
Warm reuse never passes a prior task's filesystem, process, credential, browser state, socket, secret-bearing cache, cloud identity, or provider lease directly to the next task.

Reset deletion uses exact IDs, immutable identities, tags or metadata, detach relations, and provider ETags where supported.
A replacement, unreadable relation, foreign tag, missing ETag, public NIC relation, or partial inventory records a bounded cleanup refusal and retains the resources.
No age or cost override can convert retained-for-investigation into safe deletion.

## Recovery and reconciliation classes

Every live read classifies each controller-owned slot into exactly one operator outcome:

- `assigned` means one exact VM generation is bound to one active task generation.
- `clean-warm` means a freshly reset unassigned generation exists, although normal policy immediately drives the count toward zero.
- `deallocated` means exact released worker compute is dark inside its bounded cooldown.
- `orphaned-safe-to-delete` means the release receipt owns exact residual resources after compute removal.
- `retained-for-investigation` means identity, state, or ownership is missing, conflicting, or unlanded and nothing may be deleted or duplicated.

The Azure adapter inventories only names in the reviewed resource group and separates same-name foreign owner or generation conflicts.
It never adopts unrelated subscription resources.
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

One home lock serializes local state and one pending provider action.
Each reconcile refreshes Azure before selecting the next action and stops after 64 actions even if a provider never converges.
A provider error preserves the pending action and records a bounded cleanup refusal.
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
