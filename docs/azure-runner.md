# Disposable Azure command runner

> **Isolation-only stack (2026-08-15).** UAMI cost-reservation objects,
> RBAC-zero proofs, ETag CAS admission leases, and the 72h reconcile are gone.
> Worst-case spend is now recorded in a local JSON ledger
> (`state/azure-runner/spend-ledger.json`, one entry per invocation with
> `reserved_at`/`cleaned_at`; outstanding = entries without `cleaned_at`).
> The Cost Management actual/forecast queries and the budget ceiling are
> unchanged. Absence fencing is now the minimum: VM gone without a verified
> result marks the invocation `absent-fenced`, children are cleaned, and a
> fresh `-aN` lineage attempt is allowed after a plain VM-existence check.

This document owns the architecture, state, security, restart, and operator contract for the private one-shot command substrate.
[`bin/fm-azure-runner.sh`](../bin/fm-azure-runner.sh) owns exact command mechanics, [`bin/fm-azure-runner-dispatch.sh`](../bin/fm-azure-runner-dispatch.sh) owns local-versus-Azure selection, and [`docs/azure-runner/invocation.json`](azure-runner/invocation.json) owns the invocation VM declaration.

## Boundary

The runner offloads one uncredentialed repository command to one disposable private Azure VM while Firstmate and interactive agents remain local.
It is suitable for review-independent test, lint, documentation checks, behavior suites, and Crosscheck evidence commands whose complete dependency closure is available in the exact repository snapshot or the selected runner image.
It does not run Firstmate, an author agent, a model reviewer, a browser, a no-mistakes coordinator, a fixer, branch mutation, push, CI control, or merge authority.
It does not make uncredentialed execution alone a complete Azure no-mistakes or policy-grade Crosscheck environment.
The credentialed no-mistakes control compartment is implemented by [`docs/azure-validation.md`](azure-validation.md) and consumes this substrate through its snapshot, request, result, identity, and cleanup contract.
The policy reviewer compartment remains separate.

The tracked no-mistakes command entries call the dispatch wrapper.
The wrapper executes locally by default.
Inside a no-mistakes gate worktree, an operator opts in through the run-owned file at `~/.fm-azure/runner-routing/<run-id>.json`; the daemon step discovers the run id from its own Git top-level and does not rely on `FM_HOME` or any operator-shell export reaching it.
`FM_AZURE_RUNNER_REMOTE_CLASSES` remains the compatibility selector for a direct invocation whose process actually inherits that environment; it is not the no-mistakes per-run recipe.
An absent per-run file executes the class locally and writes `executed LOCALLY` plus the absence reason into that step's stderr.
A present file that is unreadable, partial, malformed, expired, exhausted, wrongly bound, or otherwise unusable refuses by name and runs the command nowhere.
Once either selector validly chooses remote execution, the command never falls back to the Mac after any cloud, identity, quota, staging, execution, or integrity failure.
`FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES` is the only explicit local recovery selection.

No billable resource was created while implementing this code.
The first live invocation remains blocked until the foundation and this code are reviewed, landed, explicitly applied, and approved for the exact subscription.

## Request and snapshot contract

`prepare` refuses tracked changes, untracked files, and any origin identity other than a credential-free GitHub HTTPS URL.
It also refuses a detached HEAD unless the caller supplies an exact public source ref or a digest-bound private bundle for that detached commit.
By default the candidate must be reachable from a freshly advertised and fetched `refs/heads/main` default head.
The explicit `--source-ref refs/heads/<branch>` seam alone requires the candidate commit to be the exact freshly advertised and fetched head of that public branch; it never accepts an ancestor, stale tracking ref, tag, or changed remote head.
An explicit `--public-ref` may instead name only an advertised branch head or `refs/pull/<number>/head`, and the candidate must equal that ref's exact fetched head; mutable pull merge refs and unsafe ref shapes are refused, and the two source-ref seams are mutually exclusive.
A caller may additionally bind one or more exact `--public-ancestor` commits; public mode requires each commit in the freshly fetched public history, while private mode requires it in the bundle, and trusted guest bootstrap verifies each object is an ancestor of the candidate before repository networking closes.
Crosscheck evidence for a private GitHub repository supplies `--private-snapshot-bundle` without a parent reservation: the trusted host packages its clean exact-head review checkout, binds the authenticated PR ref and base ancestor, and stages only that digest-bound Git bundle so the evidence VM receives no GitHub credential.
When that arbitrary repository does not contain Firstmate's Agent Fleet lock, the `crosscheck-tool` class uses only the sealed base toolchain and records an empty Python-wheel closure instead of requiring Firstmate-specific files.
An Azure validation cell additionally supplies `--private-snapshot-bundle` with its parent-cell reservation so an unpushed pipeline-fix head can execute without prematurely changing the task branch on GitHub.
Both private modes bind one exact source ref/head, a one-ref Git bundle, digest, size, and private staging object; the validation-cell mode additionally binds its parent cell and freshly proves the public origin's trusted default ref/head.
The public proof runs in a fresh bare repository with system/global Git configuration, credentials, prompts, extra HTTP headers, and file transport disabled; private Crosscheck proof revalidates the clean checkout and bundle identities locally immediately before compute creation and retry.
No live worktree, primary home, provider account home, browser profile, or peer storage is mounted or copied.

The canonical `fm.azure-command/v1` request binds these fields:

- SHA-256 home binding derived from the canonical `FM_HOME` path, without sending that path to Azure.
- Task, task generation, deployment generation, invocation, fenced attempt, and optional parent attempt.
- Exact GitHub origin, optional trusted public default ref/head, selected source ref/head, required source ancestors, optional private bundle blob/digest/size, commit, tree, source-identity digest, command argv digest, and complete request digest.
- Resource class, reviewed VM SKU, CPU, memory, PID, disk, per-stream log, artifact, network, and wall-time limits.
- Declared repository-relative dependency paths and their file or tree digests.
- Declared repository-relative result artifact paths.
- Trusted guest-bootstrap and executor digests.

The bounded request and trusted executor travel only as ordinary Managed Run Command parameters.
In public mode trusted root fetches the exact public source ref when it is the candidate head, refuses a ref that moved after admission, and otherwise fetches the exact default-reachable commit.
Private mode stages only the exact credential-free Git bundle in the foundation's private `validation-shards` container, where the guest UAMI downloads and verifies it before deleting its token and starting repository code.
Trusted root then fetches checksum-pinned ShellCheck, uv, and any bound locked Linux wheels through the VNet NAT path and verifies every digest before repository code starts.
There is no SAS, shared key, Git credential, control-home payload, provider credential, or command-child data-plane authority.

Declared dependency paths are rehashed after the VM clones the bundle.
Package installation performed by a repository command must remain rootless and derive from committed lockfiles or the selected reviewed image.
Missing toolchain capability fails the command rather than triggering a local retry or privileged repository-controlled bootstrap.
The fixed root bootstrap installs a hard-coded Ubuntu transport and Linux test-tool package closure before repository code starts when the pinned Canonical image lacks it.
Repository code cannot alter that privileged package list, all package and staging traffic is shaped to one megabit per second and ends before deny-all command networking starts, and invocation evidence must record the resolved package/image versions during real acceptance.
The request records the exact-size, checksum-pinned ShellCheck 0.11.0 and uv 0.9.10 releases plus, when the snapshot contains the Agent Fleet `uv.lock`, the complete Linux x86_64 pytest/ruff wheel closure selected from that lock.
When that lock is present, trusted root verifies the lock, archive, file set, sizes, and hashes, creates the Agent Fleet environment with an empty cache and networking disabled, and forces repository `uv run --locked` commands to use that already-synchronized offline environment.

## Private control and VM boundary

Every Azure operation carries `FM_AZURE_SUBSCRIPTION_ID` explicitly and first proves the exact enabled tenant/subscription.
The invocation template creates one NIC in `snet-validation-shards`, one 96-GiB disposable OS disk, and one Trusted Launch Ubuntu VM.
The NIC has no public IP configuration, the subnet inherits the foundation's deny-inbound NSG, and control uses Azure Managed Run Command.
There is no SSH key, password, inbound listener, public load balancer, or public NAT rule.
The VM has exactly the foundation `validation-shards` UAMI, whose sole direct role is Storage Blob Data Contributor on the exact `validation-shards` container and which has no ARM/control-plane role.

The guest root process fetches and verifies the exact public source or downloads and verifies the exact private bundle, then verifies the pinned dependency closure before creating the child.
It remounts `/proc` with `hidepid=2` and starts repository code in a systemd private network namespace restricted to `AF_UNIX` with deny-all IP policy.
No managed-identity token exists before or during the child command.
The untrusted child receives a fixed allowlisted environment with no ambient host variables.

The command child runs as the dedicated unprivileged `fmrunner` uid with no supplemental groups, capabilities, sudo, setuid elevation, host network namespace, IMDS route, private-endpoint route, Internet route, control-plane mount, or bootstrap credential.
A root-owned trusted executor opens protected logs and drops only its child to `fmrunner`.
The systemd trusted broker applies `CPUQuota`, `MemoryMax`, zero swap, `TasksMax`, `RuntimeMaxSec`, no-new-privileges, private temporary and device namespaces, strict system/home/kernel/control-group protection, and a bounding set containing only `CAP_SETUID` and `CAP_SETGID` so it can create the unprivileged child.
After dropping uid, gid, and supplemental groups, the child proves its effective, permitted, and ambient capability sets are empty and no-new-privileges is active before executing repository code.
A loop-mounted ext4 filesystem bounds all untrusted repository, dependency, temporary, and artifact writes independently of the root filesystem.
The VM SKU and OS disk remain outer hard bounds even if a guest mechanism fails.

Each resource class leaves capacity for root result publication and permits zero repository-command network bytes:

| Class | Intended use | Command CPU | Command memory | PIDs | Task disk | Per-stream log | Artifacts | Wall time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `validation-standard` | Lint, documentation checks, ordinary tests | 3 cores | 12 GiB | 1,024 | 40 GiB | 4 MiB | 64 MiB | 1 hour |
| `behavior-heavy` | Firstmate behavior and long test suites | 3 cores | 14 GiB | 2,048 | 48 GiB | 16 MiB | 256 MiB | 3 hours |
| `crosscheck-tool` | Uncredentialed review evidence commands | 3 cores | 12 GiB | 1,024 | 40 GiB | 8 MiB | 128 MiB | 2 hours |

Strict mode defaults all classes to `Standard_D4as_v6` at 4 vCPUs/16 GiB and remains backward compatible with the reviewed `FM_AZURE_RUNNER_SKU` override.
Commissioning mode requires `FM_AZURE_RUNNER_CELL_ORDINAL=1..16`: slots 1-2 use `Standard_D4as_v7`, 3-4 D4as v6, 5-6 D4s v6, 7-8 D4ads v7, 9-10 D4ads v6, 11-12 E4as v7, 13-14 E4as v6, and 15-16 D4ds v6.
The cell ordinal, selected SKU, and exact quota family are digest-bound into the request and repeated in the reservation and VM tags. An explicit SKU override must equal the deterministic slot mapping.

A caller may lower wall time but may not raise the class maximum.
A separate reviewed image or future resource class may add tools without weakening these limits.

## Result semantics

The trusted executor drains stdout and stderr without giving the command a pipe that closes at the log bound.
Bytes beyond each stream cap are discarded and recorded with separate truncation flags.
The executor records exact ordinary exit code, terminating signal, timeout flag, duration, retained log bytes, and log digests.
A wall timeout sends the command process group `SIGTERM`, then `SIGKILL` after ten seconds, and reports exit 124 with timeout true.
A non-timeout signal reports `128 + signal` and the signal number.
Systemd control-group cleanup catches descendants that detach from the original process group.

Root copies only declared regular artifacts after the command exits.
Symlinks, devices, escaping paths, missing declared roots, and aggregate-size overflow fail result publication.
The output is one bounded tar archive containing `result.json`, both logs, and the declared artifact tree.
Only after the child has exited, trusted root obtains a fresh storage token from IMDS for the exact UAMI, uploads the archive through the blob private endpoint, and verifies its digest metadata with a HEAD request.
It deletes the token and returns the archive digest, actual boot ID, and a size-bounded canonical `result.json` through Managed Run Command.

The host validates the bounded control-plane result before accepting the command outcome; the full logs/artifacts remain private in the digest-bound archive for later private consumption:

- Published archive digest.
- Result schema, request digest, invocation, attempt, fence, snapshot, commit, tree, and command digest.
- VM resource ID, immutable VM instance ID, and guest boot ID.
- Both log digests and every declared artifact path, size, and digest are present in the trusted manifest.

A transport or integrity failure exits 125 and is not rendered as the repository command's outcome.
A verified command failure returns that command's exit code after safe collection and cleanup.
This distinction prevents remote failure from becoming a pass.

After a verified result is collected, the runner writes one summary into the command step's own stderr beside its verdict.
That run-owned proof names the invocation, exit result, immutable Azure `vm_instance_id`, and verified guest `boot_id`.
The earlier `selected REMOTE ... (dispatching)` line proves only selection; it is never evidence that Azure executed the command.
Conversely, every local path writes `executed LOCALLY` into the same step-owned log, so a routing file written after the selected step began is visible as a local run rather than being mistaken for remote execution.

## Admission, parallelism, and cost

There is no queue daemon and no warm runner compute.
An empty local queue means zero runner VMs.
Every invocation receives a separate VM, so admitted shards run concurrently without sharing process, memory, disk, temp, ports, locks, terminal servers, or task state.
The validation-cell dispatcher may request up to eight mixed-family invocations for the long behavior suite, while each invocation still passes this runner's own global admission, exact-family quota, cost, identity, and cleanup gates.
A validation-owned invocation carries an exact `capacity-parent` cell id and complete parent vCPU reservation so the cell's pre-reserved processor shape and the child VM inventory cannot be double-counted or mistaken for unrelated capacity.
Before admission and again before VM creation, the runner proves one live parent cell with the exact owner, deployment generation, home, lifecycle, id, and processor-reservation tags, then refuses a child beyond the reserved `(vCPUs - 8) / 4` slots.
Each child still receives its own durable first-day reservation for its direct compute, storage, network, monitoring, and control meters; only the already-accounted $210 shared foundation reserve is omitted from that child reservation.

Immediately before reservation and again immediately before VM creation, the controller proves the exact subscription/resource-group IDs and owner/generation tags for the named foundation storage account, zero-data admission-control account/container and ETag, controller UAMI and its sole exact effective container role including inherited/group expansion, VNet and address space, validation and private-endpoint subnets, complete NSG rule set, NAT and bound Standard public IP, blob private endpoint and endpoint NIC, named approved blob connection, private-DNS zone, VNet link, zone group/config names, and private-access properties.
It also proves current SKU capabilities and restrictions, current East US regional and selected-family free vCPU quota, month-to-date actual cost, forecast cost, the exact unambiguous Linux on-demand Consumption retail meter (never Spot, Low Priority, Windows, dev/test, reservation, or savings pricing), and active runner count.
The software cap is four active runner VMs by default and may be configured from one through 16, while live regional and per-family free-vCPU gates can impose a lower effective cap.
Each audited mixed-pool family currently has a 10-vCPU limit, so its two deterministic 4-vCPU slots are the maximum even when Azure usage reporting is stale.
The separate `st<prefix>ctl01` account has public networking, shared keys, and public blobs disabled and stores no payload data.
Its `runner-control` container is used only as a management resource: an ETag plus `If-Match` CAS fences lock owner, invocation fence, and expiry metadata.
The 60-second lock has a 10-second call deadline, monotonic last-success certificate, and 15-second safety margin.
Any renewal exception permanently fails that owner, and synchronous owner/fence/ETag renewal immediately before compute creation prevents an expired, hung, or stale writer from creating a VM.
Each invocation reserves its complete first-day worst-case dollar bound as a separately named, exactly tagged, zero-cost UAMI resource before compute creation.
Listing and summing those management resources survives controller restart without packed tag ledgers or a reachable storage data plane.
Every creation, admission list/reread, immediate pre-create proof, cleanup marker, and reconciliation/deletion proves each reservation principal has zero direct, group-derived, or inherited effective RBAC assignments, and runner VM inventory refuses any attached reservation identity.
The reservation survives controller restart and fenced retry lineage.
It is marked cleanup-verified only after exact compute absence. That exact completed marker releases its commissioning capacity slot while retaining the immutable cost evidence; the reservation resource is deleted only after a 72-hour billing-settlement interval plus an exact invocation-tagged Cost Management reconciliation.

Cost Management 429 responses use a bounded fail-closed retry and honor Azure's QPU, Consumption, or standard retry guidance.
Only a previously successful response bound to the exact subscription, resource group, endpoint, and body digest, carrying an authoritative server date and younger than four hours, may cover a retry interval beyond the bounded deadline; stale, mismatched, malformed, or absent cache data refuses admission.

`FM_AZURE_RUNNER_COST_ADMISSION_MODE` defaults to `strict`, which always requires the authoritative actual-plus-forecast gate above.
The explicit `commissioning-bounded` mode additionally requires `--confirm-cost-admission-mode commissioning-bounded`, an operator-selected concurrency from one through 16, an exact shared `FM_AZURE_RUNNER_CELL_ORDINAL` not greater than that concurrency, and `FM_AZURE_RUNNER_BUDGET_LIMIT_USD=1500`.
Its runner-local commissioning check does not independently query or claim cumulative actual or forecast spend; instead, it verifies the exact `$1,500` Monthly resource-group Budget and all eight configured alerts case-insensitively, the exact 29-resource private foundation plus only exact invocation-owned disposable resources, and exact active-VM and durable-reservation inventories.
The retained controller UAMI remains part of that exact foundation even though its reviewed role tag overlaps the disposable VM role; only the explicit VM, NIC, disk, Run Command, and TTL resource types may enter disposable classification, and any foreign role-tagged type still fails the foundation comparison.
The mandatory shared allocator reservation then supplies the cumulative actual/forecast gate for the complete resource group before compute.
Under the ARM CAS admission lease, every invocation gets a finite positive complete itemized 24-hour maximum in a mode-tagged zero-RBAC reservation. The controller sums and records existing exact reservation amounts; refuses duplicate ordinals, invocations, or foreign reservations; and refuses a seventeenth occupied slot at a configured cap of 16. For every audited family and the region, admission computes `max(live usage, exact active tagged VM vCPUs) + reservations without an active VM + the candidate`, preventing stale usage from overbooking without double-counting active VMs, and rereads the exact quota immediately before VM creation.
The strict runner-local gate remains mandatory whenever the operator has not explicitly selected commissioning mode, and it is intentionally defense in depth rather than a separate capacity owner.
Both modes acquire one exact reservation from the durable allocator in [Elastic task workers](azure-workers.md) before any runner management reservation or VM creation.
That allocator merges author assignments and disposable-runner reservations into one observed-plus-reserved 128-vCPU East US and exact-family schedule, and applies shared readable actual/forecast spend plus all durable reservation amounts even during commissioning.
A queued shared reservation caused by exact-family or regional capacity pressure waits with the same durable reservation identity for up to `FM_AZURE_RUNNER_CAPACITY_WAIT_SECONDS` (7200 seconds by default, 86400 maximum). Crosscheck evidence runners inherit the Crosscheck queue deadline. Budget, telemetry, identity, and other non-capacity refusals remain immediate. Timeout or any other pre-compute refusal releases the queued reservation after exact zero-compute proof; cleanup releases an admitted reservation only after exact VM/NIC/OS-disk absence, and ambiguity retains it.

The normal budget limit is the active $1,000 target.
An operator may select the commissioning ceiling of $1,500 through `FM_AZURE_RUNNER_BUDGET_LIMIT_USD=1500` only during the approved commissioning window.
Admission emits separate first-hour and first-day bounds itemized as VM compute, OS-disk capacity, NAT Gateway, public IP, private endpoints, private DNS, monitoring, boot diagnostics, storage capacity, storage operations, control operations, provisioning/control interval, NAT data processing, Internet egress, trusted bootstrap traffic, the conservative $210 foundation reserve, and zero repository-command egress.
The VM's complete bootstrap/output channel is shaped to one megabit per second, the trusted bootstrap terminates its exact network process group at an aggregate byte ceiling, staging input and result output have explicit byte ceilings, trusted curl has connection/elapsed/size bounds, and Azure control operations have a fixed count ceiling.
The invocation template independently installs an Azure-native `ComputeVmShutdownTask` schedule before repository execution.
Its deterministic identity, complete ownership tags, exact VM target, UTC recurrence, enabled state, and fixed preparation-time deadline are immediately adopted and rechecked at both cleanup boundaries.
The recurrence is fixed at preparation plus 23 hours, preserving an hour of slack inside the 24-hour billable ceiling.
Immediately before the VM deployment call, the controller refuses unless the schedule still has more than Azure's 30-minute activation requirement plus the complete five-minute deployment-call timeout remaining, so a delayed dispatch cannot defer shutdown to the next day's recurrence.
Azure auto-shutdown therefore deallocates the VM no later than 24 hours after preparation even if the host controller and guest are both lost.
The guest shutdown Run Command remains defense in depth, while itemized OS-disk, storage, NAT, public-IP, private-endpoint, private-DNS, and monitoring floors remain visible after compute deallocation.
Every host subprocess and Azure CLI call has a five-minute deadline.
Before every Azure call, an atomic home-scoped ledger durably increments either the control or storage category under the state lock.
The ledger is bound to the home/deployment generation and to each invocation, fence, parent, and retry-lineage root, never decrements on failure or timeout, and enforces independent 2,000-operation lineage ceilings that process restart cannot reset.
Repository-controlled execution is networkless, so untrusted code cannot create an unbounded egress charge.
An unreadable actual cost, forecast, retail rate, quota, or active inventory fails closed.
Budget pressure blocks new invocations only.
It never deletes an active VM, an uncollected result, an unfinished snapshot, or retained ambiguous state.

## Restart, fencing, and retry

Local state lives under `$FM_HOME/state/azure-runner` by default and is written mode 0600 through an atomic replace plus directory `fsync` under a per-home file lock.
The state record stores no SAS or token.
It records phase history, request/source digests, exact private result name, deployment, VM, NIC, OS disk, both Managed Run Commands, the control-plane TTL schedule, resource IDs/ETags, VM instance ID, NIC resourceGuid, disk uniqueId, Run Command and schedule identities, durable cost reservation, boot, result, and cleanup identities.
The separate atomic operation ledger is retained at home scope so deleting or recreating a controller process cannot restore its Azure-call allowance.

A controller restart runs `resume --invocation <id>`.
Resume may poll the existing Managed Run Command, collect an already published output, or continue exact cleanup.
It never submits the repository command a second time.
If the VM is missing and no verified result exists, resume proves absence through a successful exact resource inventory, marks the old lease `absent-fenced`, and refuses duplicate execution.
`retry` then rechecks that the repository still has the exact old commit, tree, command, dependency, and resource request and creates a new invocation, fence, and attempt linked to the old state.
The old invocation ID is never reused.

## Cleanup

Cleanup begins only after the trusted wrapper has verified the complete private result archive, the host has accepted the bounded result identity, and every resource identity is bound.
Before the first deletion, the controller inventories and classifies the complete disposable set, including every VM child regardless of its current tags, and re-reads every planned resource to compare the complete owner, role, home/task/task-generation, deployment-generation, invocation/attempt/fence, snapshot/command, SKU/class/cost, and cleanup-token tag set plus the recorded resource ID and ETag.
The VM also must retain its immutable instance ID, the NIC its resourceGuid and exact VM parent, the disk its uniqueId and exact managedBy VM, and the Managed Run Command its recorded provisioning identity.
The VM-absent path separately inventories all resources and Managed Run Commands in the group and refuses any unplanned or tagless VM child before deleting anything.
Deletion uses the recorded ETag as an `If-Match` condition.
A missing, foreign, replaced, or unreadable resource retains everything and reports ambiguity.

Cleanup removes resources in this exact scope and order:

1. The invocation's `execute` and `safety-shutdown` Managed Run Command child resources.
2. The exact invocation VM, whose NIC and OS disk delete options are both `Detach`.
3. The exact recorded NIC, after a stable-identity detached transition is recorded.
4. The exact recorded OS disk, after a stable-identity detached transition is recorded.
5. The exact Azure-native TTL schedule, only after exact VM absence and detached capacity cleanup are proven.
6. The exact private input snapshot blob, when either private mode supplied one.
7. The local transient request payload, while retaining local verified result/state and the private digest-bound output archive.

A VM deletion failure, timeout, unreadable response, or ambiguous absence proof retains the TTL schedule untouched so the independent deallocation deadline remains enforceable while cleanup is reconciled.

No resource-group, subnet, storage account, container, another VM, another NIC, another disk, another task prefix, or durable foundation resource is deleted.
A failed absence proof or partial delete records `cleanup-retained` and stops.
The operator may retry only that exact cleanup.

## Foundation and operator setup

The foundation creates the exact `id-<prefix>-validation-shards` UAMI and grants it Storage Blob Data Contributor only on `validation-shards`.
It also creates the private, zero-data admission-control account and management container.
The operator host uses Azure management APIs only and needs no storage private-endpoint route.
The command has no identity or network; the trusted wrapper alone retains VNet/PE/IMDS reachability for verified result publication.
After the reviewed foundation apply and before the first runner admission, the operator must independently read and accept the exact deterministic blob private-endpoint NIC `resourceGuid`, then persist it as `FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID` in the private operator configuration.
Every foundation gate compares the live NIC and the mutable deployment output to that independent accepted value, so a same-name NIC replacement plus same-name deployment rerun cannot authorize itself.

Use Azure CLI only.
Do not install an extension, change the ambient subscription default, enable storage public networking, enable shared keys, add a public IP, or weaken the subnet NSG for this runner.

Set the foundation variables from [`docs/azure-pilot.md`](azure-pilot.md), including:

```sh
export FM_AZURE_RUNNER_OPERATOR_OBJECT_ID='<exact signed-in Entra object id>'
export FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID='<independently accepted blob endpoint NIC resourceGuid>'
export FM_AZURE_RUNNER_TASK='<task or validation-run id>'
export FM_AZURE_RUNNER_GENERATION='<task or validation-run generation>'
export FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION="$FM_AZURE_SUBSCRIPTION_ID"
```

Run one heavy command directly after landed deployment and explicit approval:

```sh
bin/fm-azure-runner.sh run \
  --confirm-run \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID" \
  --task "$FM_AZURE_RUNNER_TASK" \
  --generation "$FM_AZURE_RUNNER_GENERATION" \
  --resource-class behavior-heavy \
  -- bin/fm-azure-runner-command.sh bash -c 'tests/run.sh --skip-herdr'
```

For an explicitly approved commissioning window (keep the first live smoke to one runner before scaling the configured pool):

```sh
export FM_AZURE_RUNNER_COST_ADMISSION_MODE=commissioning-bounded
export FM_AZURE_RUNNER_MAX_CONCURRENCY=16
export FM_AZURE_RUNNER_CELL_ORDINAL=1
export FM_AZURE_RUNNER_BUDGET_LIMIT_USD=1500
bin/fm-azure-runner.sh run \
  --confirm-run \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID" \
  --confirm-cost-admission-mode commissioning-bounded \
  --task "$FM_AZURE_RUNNER_TASK" \
  --generation "$FM_AZURE_RUNNER_GENERATION" \
  --resource-class behavior-heavy \
  -- bin/fm-azure-runner-command.sh bash -c 'tests/run.sh --skip-herdr'
```

### Per-run no-mistakes routing

The no-mistakes daemon is launched with only `HOME` and `PATH`.
An `export FM_AZURE_RUNNER_REMOTE_CLASSES=...` in the operator shell therefore does not reach a gate step and must not be used as the no-mistakes routing recipe.
Start the run without a machine-global selector, then, once its 26-character run id exists and before the class to offload begins, write exactly one operator-owned file at `~/.fm-azure/runner-routing/<run-id>.json`.
The full schema and exit-code contract are owned by [`bin/fm-azure-runner-routing.py`](../bin/fm-azure-runner-routing.py); the required document shape is:

```json
{
  "schema": "fm.azure-runner-routing/v1",
  "run_id": "<exact 26-character run id>",
  "classes": {
    "test": "behavior-heavy",
    "lint": "validation-standard"
  },
  "fm_home": "/absolute/operator/firstmate-home",
  "subscription": "<exact Azure subscription UUID>",
  "expires_at": "<short exact UTC expiry, YYYY-MM-DDTHH:MM:SSZ>",
  "max_dispatches": 2
}
```

Only those seven required fields and the resolver-owned optional `dispatched` counter are allowed at the top level, duplicate JSON keys are refused, and `expires_at` must use the literal UTC `Z` form shown above.

Create the routing directory and file outside every checkout, with every lexical component from `HOME` through the file owned by the invoking uid, free of symlinks, and not group- or world-writable; the file itself is a regular mode-`0600` file no larger than 64 KiB.
Publish a complete file with an atomic rename rather than writing the live path in place.
A checkout-carried `.fm-azure/runner-routing` tree is never consulted, and a symlink from the HOME-owned path into a checkout is refused.
The resolver opens with no-follow semantics and reads only the exact device/inode it checked, under the fixed byte ceiling; FIFOs, oversized files, and pathname replacement races refuse before selection.
Each selected dispatch consumes one `max_dispatches` slot under a stable sibling lock and durably records the new count before the runner starts.
Delete the exact run file after the run; expiry and the dispatch budget remain fail-closed backstops, not garbage collection.

The no-mistakes test owner must choose between its ordinary capability-derived local Herdr set and the remote-non-Herdr/local-Herdr split before it has a payload to dispatch.
It asks `bin/fm-azure-runner-dispatch.sh --inspect-selection test` for that decision.
Inspection applies the same complete routing-document, local-recovery, and dual-authority checks but never consumes a dispatch slot, and returns an exact selection binding.
The subsequent real remote dispatch must present that binding, refuses if the route was deleted, unselected, or replaced, revalidates under the stable lock, and is the only budget consumer.
A local inspection writes the exact local reason into the test step's own stderr before the local host set starts, while a malformed present authority refuses before either local or remote tests start.

The selected daemon step then asks the resolver to read the landed Azure host configuration from the provenance-checked regular file `~/.fm-azure/fleet.env`.
That file must supply `FM_AZURE_TENANT_ID`, `FM_AZURE_SUBSCRIPTION_ID`, `FM_AZURE_NAMING_PREFIX`, `FM_AZURE_STORAGE_NAME`, `FM_AZURE_OWNER_TAG`, `FM_AZURE_DEPLOYMENT_GENERATION`, and `FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID`.
The resolver opens and reads the validated inode once, evaluates those exact bounded bytes, and returns only an explicit infrastructure allowlist in encoded form rather than a mutable pathname for the dispatch shell to source later.
That allowlist covers the required identities plus the runner's documented resource-group, private data-plane, image, concurrency, budget, cost-mode, cell, SKU, and untrained-forecast infrastructure settings; unrelated `FM_AZURE_*` names are ignored.
Per-run selectors, routing roots, task/generation identity, subscription confirmation, and every `*_STATE_DIR` control are refused if `fleet.env` declares them.
Its subscription must exactly equal the routing document's explicit `subscription`, which becomes `FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION`; the routing document's explicit `fm_home` becomes `FM_HOME` and therefore selects the spend ledger.
For a routing-file dispatch, ambient runner/shared/worker state-directory overrides are cleared, so this exact `fm_home` is the sole ledger authority.
Missing, unsafe, incomplete, or disagreeing configuration refuses before runner preparation.

The `FM_AZURE_RUNNER_TASK` / `FM_AZURE_RUNNER_GENERATION` exports shown for a direct run above are an operator override, not a requirement of the no-mistakes path: `bin/fm-azure-runner-dispatch.sh` derives the per-run bindings from the ambient no-mistakes run when they are not exported.
The task and generation come from the run's own identity - the
`$FM_HOME/state/<task>.meta` whose `worktree=` records the command's Git
top-level, or, inside a no-mistakes gate worktree
(`<nm-home>/worktrees/<repo-id>/<run-id>`), the run id as `nm-<run-id>` with
the exact snapshot HEAD as the generation.
For a per-run file, the subscription confirmation and spend-ledger home come only from that written operator act and are never guessed.
For the compatibility environment selector, confirmation still passes through from the invoking process's `FM_AZURE_SUBSCRIPTION_ID` and is never synthesized.
Explicit values are honored only as a task/generation pair; half a hand-set
identity refuses.
A binding that cannot be derived fails closed with an exact error naming what
is missing, and the selected command then runs nowhere - there is no silent
local fallback, and `FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES` remains the only
explicit local opt-out.

The lint payload preserves the tracked shell owner and locked Agent Fleet command unchanged inside the dispatched argv.
For a validation-owned feature branch, the caller passes its exact current `refs/heads/<branch>` identity plus the one-ref private snapshot bundle.
The runner binds and privately stages that unpushed commit, while a changed local bundle/head/tree or public default base refuses before compute creation.
The ordinary test path runs the capability-derived real-Herdr host set locally and leaves complete behavior-inventory verification to required CI, as defined in [`configuration.md`](configuration.md#gate-defaults-no-mistakesyaml).
When the `test` class is explicitly remote, `bin/fm-no-mistakes-test-command.sh` runs the sealed non-Herdr behavior inventory plus locked Agent Fleet checks on one Azure VM while every real-Herdr declaration runs through owned guarded labs on the Mac; a failed Azure shard is never replayed locally.
Model review, document generation that requires a model, fixes, Git mutation, push, PR creation, CI monitoring, and gate decisions remain in no-mistakes' existing owner.
A configured uncredentialed documentation command may use this runner like any other command, but this bridge never moves a model document step by implication.

Select an explicit local recovery for one class only when the operator deliberately accepts Mac load:

```sh
export FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES='lint'
```

Inspect concise state:

```sh
bin/fm-azure-runner.sh queue
bin/fm-azure-runner.sh status --invocation <id>
bin/fm-azure-runner.sh cost
```

## Acceptance after explicit apply

The implementation tests use fake Azure APIs and local executor fixtures only.
They create no Azure resource and incur no charge.
Real usability remains unclaimed until the approved deployment performs this bounded acceptance:

1. Record Mac CPU, memory, swap, process count, and responsive interactive latency before launch.
2. Run at least two representative heavy commands concurrently on separate invocation VMs.
3. Prove the Mac has no child process for either repository command and remains responsive while both run.
4. Run a known local positive control and compare stdout, stderr, exit code, timeout, and signal behavior.
5. Kill one exact runner VM and prove the other invocation and result are unaffected.
6. Submit wrong snapshot/request digest, wrong VM instance/boot identity, and stale result fixtures and prove each fails closed.
7. Inspect NIC, NSG, VM identity, mount, process environment, and metadata probes to prove no public ingress, secret-bearing mount, managed identity, control home, provider credential, or peer staging is available.
8. Exercise restart during VM creation, command execution, result publication, collection, and cleanup and prove no duplicate run.
9. Drive actual and forecast budget pressure and prove new admission stops while active snapshots and results remain.
10. After safe collection, prove exact runner VM, Managed Run Command, NIC, OS disk, input blob, and output blob counts return to zero.
11. Record command wall time and Azure cost, plus Mac CPU, memory, swap, and process count after completion.

A failed leg means the runner is not yet usable.
It does not authorize automatic local fallback or a weakened security path.
