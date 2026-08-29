# Azure pilot deployment

This document owns the reviewed Azure pilot architecture and operator contract.
[`bin/fm-azure-pilot.sh`](../bin/fm-azure-pilot.sh) owns exact command mechanics, and [`docs/azure-pilot/main.json`](azure-pilot/main.json) is the Azure Resource Manager template.

## Boundary

The deployment is infrastructure for a private, elastic Firstmate fleet in East US.
No cloud resource may be created from a feature branch, a local edit, or a preview.
`apply` and every worker mutation require a clean commit already reachable from the remote default branch, an exact subscription confirmation, and an explicit mutation flag.
`apply` and `worker-create` additionally require every live gate.
The initial cloud deployment is a separate follow-up operation after review, landing, and explicit approval.

The default command, local validation, Azure validation, preview, status, and recovery guidance are read-only.
The implementation never registers a provider, requests quota, opens support, changes the ambient Azure CLI default, assigns deployment credentials, or installs tooling.
No billable deployment was performed while producing this code.

## Current capacity evidence

Live evidence was refreshed on 2026-08-12 without recording private scope identifiers.
The ten provider namespaces required by the wrapper's live gate are registered.
East US Total Regional vCPU quota is live at 128 with no observed usage.
The reviewed Dasv6 sizes are unrestricted in zones 1, 2, and 3, provide the required 2-vCPU/8-GiB and 4-vCPU/16-GiB x64 shapes, support Gen2 Trusted Launch, accelerated networking, Premium IO, and encryption at host, and have compatible zonal Premium SSD v2 capacity.
The live `standardDav6Family` limit is 10 vCPUs, and attempted increases to 96 and 32 were refused with `QuotaNotAvailableForResource`.
The optional homogeneous 96-vCPU target is therefore not available, and this foundation does not claim that a homogeneous 16-worker fleet can be allocated.
A subsequent authorized quota-ticket create used the live quota service/problem classification and authoritative existing contact fields, but Azure rejected both the initial call and one bounded diagnostic retry with `InvalidSupportPlan`; exact title/date reads confirm that no ticket exists.
No support plan purchase or upgrade is authorized or required for the immediate path.
Any future captain-owned homogeneous request must use Azure's no-charge portal quota path at `https://portal.azure.com` and does not block this foundation.

The immediate deployment profile is `foundation`.
It creates the private network, storage, identity, monitoring, budget, and compartment seams with zero supervisor or author VMs, so local Firstmate can offload isolated validation and review work as soon as the separate cell implementations land.
The existing 10-vCPU Dasv6 allowance can support either the 10-vCPU commissioning pilot or two immediate 4-vCPU runner shards after their separate reviewed implementations land.
The retained `full` profile declares 16 author slots and is the later interactive-worker target.
Its default `mixed-current` plan deterministically assigns two workers to each of eight live-reviewed families: `Standard_D4as_v6`, `Standard_D4as_v7`, `Standard_D4s_v6`, `Standard_D4ads_v7`, `Standard_D4ads_v6`, `Standard_E4as_v7`, `Standard_E4as_v6`, and `Standard_D4ds_v6`.
The optional homogeneous mode remains a future path behind its explicit 96-vCPU family gate rather than a prerequisite for foundation, runner, pilot, or mixed-family use.
The `commissioning` profile is test/fallback only.
Every selected worker or runner SKU has exactly 4 vCPUs, at least 16 GiB, Gen2 Trusted Launch, three-zone availability, Premium IO, and encryption-at-host support.

## Topology and isolation

The subscription deployment creates the East US resource group and a nested incremental resource deployment.
Mandatory tags identify workload, environment, cleanup ownership, deployment generation, immediate-acceptance activation, cost targets, and capacity reservations.
The stable deployment generation, role, worker slot, VM, identity, and retained-disk tags are the integration seam for exact home, session, workspace, pane, VM, task, and generation binding.

The optional supervisor in the `commissioning` and `full` profiles is trusted control-plane capacity.
The default `foundation` profile creates no supervisor, and Firstmate and its persistent secondmates remain local.
If a later profile activates the supervisor, persistent cloud secondmates stay on that control plane and request elastic task workers.
A general worker hosts exactly one task-scoped crewmate plus minimal lifecycle supervision.
A worker never hosts a secondmate, another supervisor, or a nested team.
Worker OS capacity is disposable, while its LUKS2 task-state and provider-account disks detach and remain retained on VM deletion.

The template defaults to `foundation` with empty worker slot/SKU arrays and no supervisor VM, so the foundation itself has zero warm compute.
The separate `full` configuration declares slots 1 through 16 and an exact SKU for every slot; that inventory never permits warm-idle workers.
Omitted workers consume no VM charge, and incremental slot deployment can create or reconcile one worker without deleting resources for other slots.
The fallback `commissioning` profile declares only slots 1 and 2.

Dedicated private subnets, managed identities, and non-public evidence containers reserve separate boundaries for Crosscheck credentialed reviewer/model cells, Crosscheck uncredentialed tool cells, and fresh networkless verifier cells.
The verifier subnet has no NAT attachment, disables default outbound access, and uses its own NSG with explicit deny-all inbound and outbound rules, including VNet and private-endpoint destinations.
No validation, reviewer, tool, or verifier VM is created by this template.
Those workload classes must scale to zero and may not mount a control home; subnet and identity separation never implies pre-provisioned compute.
The policy reviewer identity is separate from the browser/tool identity so the follow-up can preserve a credentialed-reviewer and uncredentialed-tool boundary.
The template does not claim that moving a shared singleton daemon into Azure solves contention.
Generic isolated invocation behavior is owned by [`docs/azure-runner.md`](azure-runner.md), and review-specific compartment behavior is owned by [`docs/azure-crosscheck.md`](azure-crosscheck.md).

The live 128-vCPU regional limit can cover a 2-vCPU supervisor, sixteen 4-vCPU mixed-family author workers, and a 62-vCPU landing reserve.
That headroom is reserved for isolated validation, Crosscheck, browser, replacement, recovery, and ancillary capacity.
Author admission must stop before consuming the capacity needed to review and land work.
Homogeneous full mode retains the hard 96-vCPU Dasv6 family gate and is currently unavailable because its live family limit is 10.
Mixed full mode instead proves enough free quota in every exact selected family for its assigned two-worker slice while still requiring all 128 regional vCPUs and the 62-vCPU landing reserve.
SKU and quota eligibility are not a capacity reservation, so every allocation still requires a fresh live gate.
Every later validation/review request must prove its selected family's live quota rather than borrowing an assumption from author capacity.

## Network and private administration

VM NICs have private addresses only and no public-IP configuration.
Every outbound-capable VM subnet uses Standard NAT Gateway with one Standard static outbound public IP.
The networkless-verifier subnet has no NAT attachment or other outbound path.
There is no inbound NAT, load balancer, Bastion, public SSH, public mosh, or public Herdr rule.
NSGs explicitly deny Internet inbound.
The elastic validation, policy-review, and browser subnets also deny cross-compartment VNet inbound by default.

Storage and Key Vault disable public network access and use blob/vault private endpoints, private DNS zones, and VNet links.
The blob endpoint uses the deterministic `nic-<prefix>-pe-blob` network-interface name.
The foundation deployment outputs both that exact NIC resource ID and its Azure `resourceGuid`.
After the reviewed apply, the operator independently accepts that GUID into private configuration as `FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID`.
The runner proves the live NIC and deployment output both equal that independently retained value, plus the endpoint's forward reference, the NIC's reverse endpoint relation, its exact private subnet configuration, its tags/generation, and absence of any VM relation at every foundation gate.
The private-endpoint subnet disables private-endpoint network policies; compute subnets do not.

Private overlay enrollment is an explicit post-deploy acceptance step.
An enrollment key must be short-lived and supplied through the overlay's private enrollment mechanism, never an ARM parameter, image, extension setting, custom data value, log, monitoring field, or state artifact.
The template accepts one out-of-band SSH public key as a secure provisioning parameter and installs it for authenticated administration only over the private overlay.
No public IP, inbound NAT, public listener, or NSG allow rule exposes SSH to the Internet.

## Compute and retained data

The image is a pinned x64 Ubuntu 24.04 Gen2 release.
Every VM uses Trusted Launch, Secure Boot, vTPM, encryption at host, a reproducible Standard SSD OS disk, disabled password authentication, and exactly one out-of-band public key for private-overlay SSH authentication.
The template supplies no custom data and contains no overlay key, provider credential, LUKS key, or Herdr credential.

Each VM gets its own user-assigned identity.
Each task worker gets a container-scoped Storage Blob Data Contributor assignment only for its own state container.
The supervisor has separate access to supervisor state and artifact containers.
Validation, Crosscheck, and browser evidence containers and identities are distinct seams for the follow-up access policy.
Key Vault uses Azure RBAC, disables public access, enables 90-day soft deletion and purge protection, and intentionally receives no secret through the template.
Per-disk LUKS unlock material and secret-scoped identity grants are created out of band during acceptance; provider-account credentials never belong in Key Vault.

Provider-account disks are 8-GiB zonal Premium SSD v2 disks with fixed IOPS/throughput, no host cache, denied export/network access, no snapshot policy, and `Detach` on VM deletion.
Task-state disks are separate 64-GiB zonal Standard SSD disks with the same detach and guest-LUKS requirement.
Neither disk may be cloned, imaged, routinely backed up, or deleted before exact work/state proof.
Loss of an account disk requires provider reauthentication.

## Durable state and Lavish

The ZRS StorageV2 account requires encrypted transport and TLS 1.2, defaults to Entra authentication, and disables public blob access, routine shared-key access, and public network access.
Blob versioning, 35-day change feed, 35-day blob/container soft deletion, and 30-day point-in-time restore are enabled.
State sync must run every five minutes and alert when its newest non-secret durable point exceeds 15 minutes.
Only allowlisted Firstmate state, reports, backlog, and non-secret configuration may sync.
Provider-account mounts, tokens, credential files, shell history, caches, repositories, transient locks, and control-home data are excluded.

Lavish remains a downloaded self-contained form artifact with a returned answer file.
This deployment creates no hosted form service and no remote-write form endpoint.

## Monitoring and cost controls

The deployment creates a 30-day Log Analytics workspace with a 0.25-GiB daily cap, an action group, Azure Monitor Agent, a Linux data collection rule, heartbeat alerts, an 80-percent filesystem alert, a 15-minute state-sync-silence alert seam, and a storage/private-endpoint availability alert.
The worker rule compares distinct workers seen in its evaluation window with the exact declared worker count, and the state-sync rule alerts when the window contains no freshness record, so total emitter silence remains detectable.
Collection is limited to heartbeat, safe performance counters, and warning-or-higher system events.
Environment values, command lines, auth payloads, credential mounts, provider sessions, and secret contents are not collected.
The application follow-up must emit the non-secret state-sync freshness record consumed by the alert and prove every alert during acceptance.

The budget uses a $1,500 commissioning ceiling.
It sends actual and forecast alerts at the percentages corresponding to $750, $1,000, $1,250, and $1,500.
At $1,000, scheduling should prefer scale-to-zero and efficiency, but required bring-up, validation, review, recovery, and landing remain admitted.
At $1,500 actual or forecast, new discretionary author launches stop, while active, validating, reviewing, recovering, and unlanded work is never terminated for cost reasons.
The steady-state scheduler target defaults to $1,000 and remains configurable without infrastructure redesign.
The 3,500 aggregate D4-equivalent worker-hour value is a planning and alert threshold, not a commissioning hard stop; 400 hours are reserved conceptually for validation and review.

Observed East US Linux rates for the reviewed mixed author plan range from $0.182 to $0.249 per worker-hour, with the Dasv6 supervisor at $0.0908/hour.
One Dasv6 supervisor plus two continuous Dasv6 workers is about $332/month for VM compute.
The full mixed plan's average worker rate is about $0.218/hour, making the 3,500-hour planning arithmetic, supervisor, NAT/outbound IP, and conservative $210 reserve about $1,077/month.
Sixteen mixed workers plus the supervisor and NAT/outbound IP running continuously is about $2,653/month before disks, validation/review/browser capacity, Log Analytics, blob capacity and operations, network transfer, taxes, discounts, or credits.
The separate one-shot validation seam defaults to `Standard_D4as_v6` (4 vCPUs/16 GiB), so two immediate shards fit inside the existing 10-vCPU Dasv6 allowance.
Requested behavior parallelism fans into mixed-family identity-less command VMs only after the requested shape fits current author/review demand under the shared East US admission ceiling.
East US homogeneous-family increases are unavailable on this sponsorship subscription, so the runner never waits for 96 homogeneous family vCPUs and may instead select one of the foundation's reviewed mixed-family shapes only after proving that exact family's current free quota and retail rate.
Quota is capacity, not permission to spend; actual and forecast billing telemetry is authoritative.
Credits remain unverified and are never assumed.

## Operator setup

Use Azure CLI only; do not install Bicep, Terraform, OpenTofu, extensions, packages, or another deployment tool for this workflow.
Set private values in the invoking environment without committing or printing them:

```sh
export FM_AZURE_TENANT_ID='<exact tenant>'
export FM_AZURE_SUBSCRIPTION_ID='<exact subscription>'
export FM_AZURE_ADMIN_EMAIL='<verified billing notification address>'
export FM_AZURE_ADMIN_USERNAME='<private local administrator name>'
export FM_AZURE_ADMIN_SSH_PUBLIC_KEY='<public key for private-overlay SSH authentication>'
export FM_AZURE_RUNNER_OPERATOR_OBJECT_ID='<exact signed-in Entra object id>'
export FM_AZURE_OWNER_TAG='<cleanup owner>'
export FM_AZURE_NAMING_PREFIX='<reviewed lowercase prefix>'
export FM_AZURE_STORAGE_NAME='<globally available name>'
export FM_AZURE_KEY_VAULT_NAME='<globally available name>'
export FM_AZURE_DEPLOYMENT_GENERATION='<stable generation>'
export FM_AZURE_BUDGET_START_DATE='<YYYY-MM-01>'
```

Optional reviewed inputs are `FM_AZURE_CAPACITY_PROFILE=foundation`, `FM_AZURE_AUTHOR_CAPACITY_MODE=mixed-current`, `FM_AZURE_VM_FAMILY=Dasv6`, the matching `FM_AZURE_WORKER_SLOTS` and `FM_AZURE_WORKER_SKUS` lists, `FM_AZURE_RUNNER_VALIDATION_SKU=Standard_D4as_v6`, `FM_AZURE_PROTECT_DURABLE_STATE=0`, `FM_AZURE_STEADY_STATE_BUDGET_TARGET_USD=1000`, `FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD=3500`, and `FM_AZURE_CLEANUP_TIMEOUT_SECONDS=900`.
Do not change the ambient Azure CLI default.
Every script operation supplies the exact subscription, and the template independently invalidates a tenant/subscription mismatch.

## Validate, preview, apply, and status

Run local validation without cloud input:

```sh
bin/fm-azure-pilot.sh local-validate
```

Run Azure template validation and a sanitized what-if after setting the private environment:

```sh
bin/fm-azure-pilot.sh validate
bin/fm-azure-pilot.sh preview
```

Preview prints change counts only and suppresses resource identifiers and private parameter values.
It is evidence, never permission to apply.

After the code is reviewed, landed, separately approved, and every live gate is green, apply exactly:

```sh
bin/fm-azure-pilot.sh apply \
  --confirm-apply \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

The command refuses a local-only commit, a dirty deployment file, a scope mismatch, a provider mismatch, another region, a restricted or undersized SKU, an invalid profile/mode/slot/SKU mapping, insufficient selected-family quota, less than 128 regional quota or the 62-vCPU landing reserve for `full`, unavailable or foreign global names, or an unreadable/out-of-policy retail projection.
It does not register providers or request quota.

Read status without printing resource identifiers:

```sh
bin/fm-azure-pilot.sh status
```

After acceptance, rerun apply with `FM_AZURE_PROTECT_DURABLE_STATE=1` to add CanNotDelete locks to storage and Key Vault.

## Disposable worker lifecycle

Creating one worker is an incremental landed-template deployment and needs an explicit billable confirmation.
The wrapper freezes the exact one-slot/SKU plan before live gates and sets a template parameter that admits only that singleton while keeping every ordinary profile deployment at 0, 2, or 16 workers:

```sh
bin/fm-azure-pilot.sh worker-create \
  --slot 3 \
  --confirm-create \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

Deallocation and deletion are explicit too:

```sh
bin/fm-azure-pilot.sh worker-deallocate \
  --slot 3 \
  --confirm-deallocate \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"

bin/fm-azure-pilot.sh worker-delete \
  --slot 3 \
  --task-state-preserved \
  --confirm-delete \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

Worker deletion removes disposable VM/NIC/OS capacity and retains both encrypted data disks.
A later worker may adopt those disks only after exact slot, VM, task, home, and generation recovery proof.

The urgent one-shot runner is specified by [`docs/azure-runner.md`](azure-runner.md) and implemented by `bin/fm-azure-runner.sh`.
It creates one-invocation private controller VMs in `snet-validation-shards` rather than reusing author-worker slots or retained provider/task disks.
The foundation grants `id-<prefix>-validation-shards` Blob Data Contributor only on the exact `validation-shards` container and no ARM role.
Trusted root uses that identity only after the networkless repository command exits to upload and verify the private result archive; the command receives no identity, token, SAS, or network namespace.
The separate `st<prefix>ctl01` account has public networking, shared keys, and public blobs disabled and holds no payload data; its `runner-control` management child resource provides ETag/If-Match admission fencing while exact tagged zero-cost UAMIs provide durable per-invocation cost reservations.
Its reviewed validation SKU seam defaults to the live-verified 4-vCPU/16-GiB `Standard_D4as_v6`, accepts the foundation's reviewed mixed-family alternatives, and re-proves that selected family's quota, SKU capability, budget, forecast, and retail rate before every invocation.
The runner owns snapshot upload, command/result protocol, fencing, sandboxing, restart-safe collection, and exact cleanup.
The intended first real use is parallel heavy test, lint, and behavior commands while the local primary remains responsive.

The queued fleet lifecycle implementation is specified in [`docs/azure-workers.md`](azure-workers.md) and owns budget/forecast admission, zero-warm-idle scheduling, landing-capacity reservation, provider-session revocation, and application health while preserving the role topology above.

## Acceptance and immediate use

There is no time-based canary and no mandatory soak.
Foundation acceptance keeps Firstmate local while making isolated Azure validation/review capacity eligible for one-shot commands and Crosscheck.
It does not wait for remote Herdr or full author-worker migration.
Before those environments are called usable, the bounded deployment window must prove:

1. Exact tenant/subscription, provider, profile-specific regional/family quota, every selected SKU, region, name, and current-cost gate is green.
2. No VM public IP, public inbound rule, public Herdr listener, or public storage/Key Vault path exists.
3. Private overlay administration works without logging or retaining its enrollment key.
4. A credentialed Crosscheck reviewer/model cell, an uncredentialed Crosscheck tool cell, and a fresh networkless verifier each use only their exact private identity/network/storage boundary.
5. One disposable validation worker launches from the clean pinned image, completes a representative heavy command, and is removed without exposing public ingress or broad identity.
6. Five-minute durable-state sync and a restore no older than 15 minutes are observed.
7. One representative scout finishes end to end and teardown preserves intended state while removing disposable compute.
8. Every budget/forecast and health alert exists and is exercised.
9. A policy-grade Azure Crosscheck on a real current head runs while local Firstmate remains responsive; disposable review/tool/verifier capacity is removed afterward.
10. The Mac rollback remains reachable.

If any leg fails, the Azure validation/review environment is not called usable, local remains authoritative, and the exact failed leg is reported with evidence.
If every leg passes, validation and policy review may use Azure immediately while interactive Firstmate work remains local.
Remote Herdr and full author-worker activation have their own later acceptance gate.
Already-running local work finishes locally and is never migrated in place.

## Herdr boundary

Herdr is the required primary cloud terminal/session interface for a later remote interactive supervisor and author fleet.
tmux exists only as a recovery fallback for that topology.
The standalone Azure validation plane uses private control-plane and command interfaces while Firstmate remains local, so its acceptance and Mac-relief eligibility do not wait for remote Herdr.

The template exposes empty Herdr release, artifact URI, and integrity-pin seams but installs nothing from them.
They remain empty until the independent Linux and remote topology evidence establishes a supported pinned artifact, network, authentication, and endpoint contract.
No speculative Herdr package, port, command, public listener, enrollment secret, or distributed-worker behavior appears here.
Pane survival never owns durable work; an endpoint is created or adopted only after exact recovery proof.

## Recovery and destruction

Print the recovery order with:

```sh
bin/fm-azure-pilot.sh recovery
```

The recovery objective is a clean IaC rebuild, private re-enrollment, retained-disk adoption, and blob point-in-time restore in two hours, with the newest durable point no older than 15 minutes.
Supervisor recovery applies only after an explicitly selected non-foundation profile creates one; the foundation profile keeps Firstmate local.
The current Mac stays unchanged and reachable for 30 days after accepted cutover as rollback and Apple-only compatibility capacity.

Full destruction is deliberately difficult and requires proof that state was exported, provider sessions were revoked, and retained disks may be deleted.
Both retained-disk deletion flags are mandatory because resource-group deletion cannot retain disks inside the group:

```sh
bin/fm-azure-pilot.sh destroy \
  --confirm-destroy \
  --state-export-confirmed \
  --provider-sessions-revoked \
  --delete-retained-disks \
  --confirm-delete-retained-disks \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

The script inventories every VM, OS disk, task-state disk, and provider-account disk before mutation, refuses unknown or oversized inventories, and routes every scope, provider, SKU, quota, name, validation, preview, apply, worker, and cleanup Azure CLI call through one retained-state owner with a configurable 60-to-3,600-second deadline.
Each validate/apply/worker call records `submitted`, `completed`, or `retained` operation state atomically; a timeout or failure preserves exact deployment/resource-group identity and requires live reconciliation before retry.
It deallocates and deletes VMs first, removes durable-resource locks, deletes retained task/account disks only under the second explicit confirmation, and submits resource-group deletion last.
Key Vault purge protection remains in force; the script never purges it.
A budget event never invokes destruction or automatically terminates active, validating, reviewing, recovering, or unlanded work.
