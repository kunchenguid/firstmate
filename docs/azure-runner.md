# Disposable Azure command runner

This document owns the architecture, state, security, restart, and operator contract for the private one-shot command substrate.
[`bin/fm-azure-runner.sh`](../bin/fm-azure-runner.sh) owns exact command mechanics, [`bin/fm-azure-runner-dispatch.sh`](../bin/fm-azure-runner-dispatch.sh) owns local-versus-Azure selection, and [`docs/azure-runner/invocation.json`](azure-runner/invocation.json) owns the invocation VM declaration.

## Boundary

The runner offloads one uncredentialed repository command to one disposable private Azure VM while Firstmate and interactive agents remain local.
It is suitable for review-independent test, lint, documentation checks, behavior suites, and Crosscheck evidence commands whose complete dependency closure is available in the exact repository snapshot or the selected runner image.
It does not run Firstmate, an author agent, a model reviewer, a browser, a no-mistakes coordinator, a fixer, branch mutation, push, CI control, or merge authority.
It does not make uncredentialed execution alone a complete Azure no-mistakes or policy-grade Crosscheck environment.
Those credentialed control and reviewer compartments remain separate follow-ups and consume this substrate through its snapshot, request, result, identity, and cleanup contract.

The tracked no-mistakes command entries call the dispatch wrapper.
The wrapper executes locally by default.
An operator opts in each command class with `FM_AZURE_RUNNER_REMOTE_CLASSES`, and a selected remote command never falls back to the Mac after any cloud, identity, quota, staging, execution, or integrity failure.
`FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES` is the only explicit local recovery selection.

No billable resource was created while implementing this code.
The first live invocation remains blocked until the foundation and this code are reviewed, landed, explicitly applied, and approved for the exact subscription.

## Request and snapshot contract

`prepare` refuses a detached HEAD, tracked changes, and untracked files.
It creates a Git bundle for the exact named-branch `HEAD`, records the commit and tree object IDs, verifies the bundle, and hashes the complete bundle.
No live worktree, primary home, provider account home, browser profile, or peer storage is mounted or copied.

The canonical `fm.azure-command/v1` request binds these fields:

- SHA-256 home binding derived from the canonical `FM_HOME` path, without sending that path to Azure.
- Task, task generation, deployment generation, invocation, fenced attempt, and optional parent attempt.
- Exact commit, tree, Git-bundle digest and bytes, command argv digest, and complete request digest.
- Resource class, reviewed VM SKU, CPU, memory, PID, disk, per-stream log, artifact, network, and wall-time limits.
- Declared repository-relative dependency paths and their file or tree digests.
- Declared repository-relative result artifact paths.
- Trusted guest-bootstrap and executor digests.

The input object contains only `request.json`, `snapshot.bundle`, and the trusted executor.
The private `validation-shards` container stores it under a prefix bound to home, task, generation, invocation, and attempt.
The host stages with Entra authentication and gives the VM root bootstrap one short-lived read SAS for the exact input blob and one create/write SAS for the exact output blob.
The repository command never receives either capability.
The controller principal has data access only to `validation-shards` plus Storage Blob Delegator authority, so its user-delegation SAS remains bounded by that data scope.

Declared dependency paths are rehashed after the VM clones the bundle.
Package installation performed by a repository command must remain rootless and derive from committed lockfiles or the selected reviewed image.
Missing toolchain capability fails the command rather than triggering a local retry or privileged repository-controlled bootstrap.
The fixed root bootstrap installs a hard-coded Ubuntu transport and Linux test-tool package closure before repository code starts when the pinned Canonical image lacks it.
Repository code cannot alter that privileged package list, all package and staging traffic ends before deny-all command networking starts, and invocation evidence must record the resolved package/image versions during real acceptance.
The unprivileged command helper then installs checksum-verified ShellCheck and hash-pinned uv into the invocation-private home.

## Private control and VM boundary

Every Azure operation carries `FM_AZURE_SUBSCRIPTION_ID` explicitly and first proves the exact enabled tenant/subscription.
The invocation template creates one NIC in `snet-validation-shards`, one 96-GiB disposable OS disk, and one Trusted Launch Ubuntu VM.
The NIC has no public IP configuration, the subnet inherits the foundation's deny-inbound NSG, and control uses Azure Managed Run Command.
There is no SSH key, password, inbound listener, public load balancer, public NAT rule, or VM managed identity.
The VM therefore has no GitHub, model-provider, browser, reviewer, author-account, control-home, peer-worker, or broad cloud identity.

Managed Run Command receives object SAS values as protected parameters.
The guest root process downloads and verifies the exact input before creating the child.
It clears capability variables, remounts `/proc` with `hidepid=2`, and starts repository code only after systemd installs deny-all IP networking for that command cgroup.
The untrusted child receives a fixed allowlisted environment with no ambient host variables.

The command child runs as the dedicated unprivileged `fmrunner` uid with no supplemental groups, capabilities, sudo, setuid elevation, IP network route, control-plane mount, or bootstrap write access.
A root-owned trusted executor opens protected logs and drops only its child to `fmrunner`.
The systemd unit applies `CPUQuota`, `MemoryMax`, zero swap, `TasksMax`, `RuntimeMaxSec`, no-new-privileges, private temporary and device namespaces, strict system/home/kernel/control-group protection, an empty capability bounding set, and control-group process cleanup.
A loop-mounted ext4 filesystem bounds all untrusted repository, dependency, temporary, and artifact writes independently of the root filesystem.
The VM SKU and OS disk remain outer hard bounds even if a guest mechanism fails.

Each resource class leaves capacity for root result publication and permits zero repository-command network bytes:

| Class | Intended use | Command CPU | Command memory | PIDs | Task disk | Per-stream log | Artifacts | Wall time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `validation-standard` | Lint, documentation checks, ordinary tests | 3 cores | 12 GiB | 1,024 | 40 GiB | 4 MiB | 64 MiB | 1 hour |
| `behavior-heavy` | Firstmate behavior and long test suites | 3 cores | 14 GiB | 2,048 | 48 GiB | 16 MiB | 256 MiB | 3 hours |
| `crosscheck-tool` | Uncredentialed review evidence commands | 3 cores | 12 GiB | 1,024 | 40 GiB | 8 MiB | 128 MiB | 2 hours |

All classes default to `Standard_D4as_v6` at 4 vCPUs/16 GiB.
Two concurrent default shards fit the existing 10-vCPU Dasv6 allowance without waiting for the unavailable 96-vCPU increase.
`FM_AZURE_RUNNER_SKU` may select one reviewed current 4-vCPU/16-GiB family for a later mixed-family cell, and every invocation proves that exact family's live free quota before creation.

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
The guest hashes that complete archive, uploads it with the exact output capability, and returns the digest plus actual boot ID through Managed Run Command.

The host downloads the exact output object and verifies all of these before accepting the command outcome:

- Published archive digest.
- Result schema, request digest, invocation, attempt, fence, snapshot, commit, tree, and command digest.
- VM resource ID, immutable VM instance ID, and guest boot ID.
- Both log digests.
- Every artifact path, size, digest, declaration, and archive-manifest correspondence.

A transport or integrity failure exits 125 and is not rendered as the repository command's outcome.
A verified command failure returns that command's exit code after safe collection and cleanup.
This distinction prevents remote failure from becoming a pass.

## Admission, parallelism, and cost

There is no queue daemon and no warm runner compute.
An empty local queue means zero runner VMs.
Every invocation receives a separate VM, so two admitted shards run concurrently without sharing process, memory, disk, temp, or task state.

Before staging or creating a VM, the controller proves the exact scope and the named foundation storage account, VNet, validation-shard subnet, private NSG/NAT binding, blob private endpoint, deployment generation, private-access settings, current SKU capabilities and restrictions, current East US regional and selected-family free vCPU quota, month-to-date actual cost, forecast cost, current retail rate, and active runner count.
The software cap is four active runner VMs and may be configured only from one through eight, while live regional and per-family free-vCPU gates can impose a lower effective cap.
The current Dasv6 allowance admits two default 4-vCPU runners and refuses a third.
A short renewable Azure Blob lease serializes count-and-create admission across controllers without a machine-wide singleton daemon.
Lease loss stops before repository execution and retains exact state for reconciliation.

The normal budget limit is the active $1,000 target.
An operator may select the commissioning ceiling of $1,500 through `FM_AZURE_RUNNER_BUDGET_LIMIT_USD=1500` only during the approved commissioning window.
Admission reserves the foundation's conservative $210 shared-meter allowance, $40 for runner disk, operations, diagnostics, and bounded trusted-bootstrap traffic, plus 24 hours of the selected-SKU compute rate.
The invocation template independently installs a 24-hour self-shutdown timer before repository execution, and every host subprocess and Azure CLI call has a five-minute deadline.
Repository-controlled execution is networkless, so untrusted code cannot create an unbounded egress charge.
An unreadable actual cost, forecast, retail rate, quota, or active inventory fails closed.
Budget pressure blocks new invocations only.
It never deletes an active VM, an uncollected result, an unfinished snapshot, or retained ambiguous state.

## Restart, fencing, and retry

Local state lives under `$FM_HOME/state/azure-runner` by default and is written mode 0600 through an atomic replace plus directory `fsync` under a per-home file lock.
The state record never stores a SAS value.
It records phase history, request and input digests, exact staging names, deployment, VM, NIC, OS disk, Managed Run Command, immutable VM instance, boot, result, and cleanup identities.

A controller restart runs `resume --invocation <id>`.
Resume may poll the existing Managed Run Command, collect an already published output, or continue exact cleanup.
It never submits the repository command a second time.
If the VM is missing and no verified result exists, resume proves absence through a successful exact resource inventory, marks the old lease `absent-fenced`, and refuses duplicate execution.
`retry` then rechecks that the repository still has the exact old commit, tree, command, dependency, and resource request and creates a new invocation, fence, and attempt linked to the old state.
The old invocation ID is never reused.

## Cleanup

Cleanup begins only after the complete result archive and every bound identity have been verified and retained locally.
Before deletion, the controller re-reads every live disposable resource and compares invocation, fence, snapshot, and command tags plus the recorded resource ID and ETag; the VM also must retain its immutable instance ID, while the NIC and disk must remain managed by that exact VM.
Deletion uses the recorded ETag as an `If-Match` condition.
A missing, foreign, replaced, or unreadable resource retains everything and reports ambiguity.

Cleanup removes resources in this exact scope and order:

1. The invocation's Managed Run Command child resource.
2. The exact invocation VM.
3. The exact recorded NIC.
4. The exact recorded OS disk.
5. The exact input and output staging blobs.
6. The local transient input payload, while retaining local verified result and state.

No resource-group, subnet, storage account, container, another VM, another NIC, another disk, another task prefix, or durable foundation resource is deleted.
A failed absence proof or partial delete records `cleanup-retained` and stops.
The operator may retry only that exact cleanup.

## Foundation and operator setup

The foundation adds `FM_AZURE_RUNNER_OPERATOR_OBJECT_ID` to the private operator environment.
Its ARM template grants that exact principal Storage Blob Delegator at the pilot storage account and Storage Blob Data Contributor only on `validation-shards`.
The runner VM itself receives no role assignment or managed identity.
The operator host must have private data-plane reachability to the storage private endpoint, normally through the separately accepted private overlay.
Failure to reach the private endpoint is a hard transport failure and never enables public storage or SSH as a shortcut.

Use Azure CLI only.
Do not install an extension, change the ambient subscription default, enable storage public networking, enable shared keys, add a public IP, or weaken the subnet NSG for this runner.

Set the foundation variables from [`docs/azure-pilot.md`](azure-pilot.md), including:

```sh
export FM_AZURE_RUNNER_OPERATOR_OBJECT_ID='<exact signed-in Entra object id>'
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

Select no-mistakes command classes explicitly:

```sh
export FM_AZURE_RUNNER_REMOTE_CLASSES='test=behavior-heavy,lint=validation-standard'
no-mistakes axi run --intent '<captain goal and implementation context>'
```

The lint payload preserves the tracked shell owner and locked Agent Fleet command unchanged inside the dispatched argv.
The ordinary test path preserves the existing complete local command.
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
