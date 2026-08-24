# Azure validation cells

> **Isolation-only stack (2026-08-15).** This single-operator harness was
> deliberately stripped to its one real requirement: resource-contention
> isolation (one VM per run/shard) plus wallet protection (cost-ceiling
> admission, Cost Management actual/forecast checks, DevTestLab TTL) and a
> private NIC. The LUKS worktree/credential-disk machinery, disk content
> bindings, custody chains, TrustedLaunch requirements, UAMI cost-reservation
> objects, and multi-step absence-fence proofs described below are GONE.
> Today: the worktree is a plain ext4 data disk; the GitHub token is injected
> at boot as a run-command parameter; persistent provider auth (pi-codex
> primary, one claude cross-check profile) lives on the `fm-auth-home` Azure
> Files share and syncs into the cell home each boot; runner spend is tracked
> in a local JSON ledger; and `bin/fm-azure-cell-image.sh` can bake a golden
> image preferred via `FM_AZURE_VM_IMAGE_ID`. Dispatch is multi-lane:
> `FM_AZURE_VALIDATION_LANES` (default 4) concurrent cells, FIFO admission of
> any number of queued generations, lane index mapped deterministically onto
> the four-family coordinator SKU pool; `queue` shows lanes used and queue
> order. Sections below describing the removed machinery are retained as
> history until rewritten.

This document owns the architecture, identity, admission, recovery, credential, cleanup, and operator contract for elastic Azure no-mistakes validation cells.
[`bin/fm-azure-validation.sh`](../bin/fm-azure-validation.sh) owns exact host commands, [`bin/fm-azure-validation.py`](../bin/fm-azure-validation.py) owns the state machine, and [`docs/azure-validation/cell.json`](azure-validation/cell.json) owns the per-cell Azure declaration.
The private foundation remains owned by [`docs/azure-pilot.md`](azure-pilot.md), and credential-free command VMs remain owned by [`docs/azure-runner.md`](azure-runner.md).

## Boundary

Firstmate and its primary supervisor remain local.
The local dispatcher may inspect Git identity, package an exact clean Git bundle, make bounded Azure control-plane calls, exchange digest-bound objects through the private blob endpoint, and verify returned protocol objects.
Private blob operations require the operator host's authenticated private-overlay route; an absent route fails closed and never enables public storage, shared keys, SAS fallback outside the declared exact-object capabilities, or local command execution.
It never executes lint, tests, review commands, fixes, no-mistakes, a model provider, GitHub mutation, or CI control on the primary machine.
A queued request is non-billable and creates no Azure resource.

One admitted cell owns one no-mistakes run or a deliberately bounded continuation of that exact run.
It has its own VM, boot identity, systemd cgroup, process namespace, no-mistakes daemon and database, home, temp root, cache root, logs, private durable worktree disk, cell storage identity, and private shard container.
No cell mounts `FM_HOME`, another task worktree, another task's auth home, or another cell container.
No operation stops, starts, updates, or inspects a local legacy no-mistakes daemon.

Remote Herdr is not part of this path.
Later Herdr proxy tabs may display state, but validation submission, ask-user responses, recovery, evidence collection, and cleanup use Azure Resource Manager, Managed Run Command, and the private storage endpoint.
The runner's separate per-run no-mistakes routing path may seal a detached gate HEAD as a direct private bundle with ordinary standalone capacity accounting; that path is not a validation cell or a child of one.

No Azure resource was created while implementing this feature.
Live Azure acceptance of these cells runs from released public main under separate explicit billable authorization; the first live Stage C pipeline acceptance has occurred and is recorded in the Live acceptance record section, while the full multi-leg checklist in the Live acceptance section remains unperformed.
The released private foundation, its PR 136 inventory correction, and the released whole-fleet allocator are the integration base, and the dispatcher consumes the released runner's exact foundation/controller-identity contract rather than a partial parallel proof.

## Capacity and cost shape

The default `validation-heavy` control cell requires 8 vCPUs and at least 32 GiB.
The dispatcher live-selects the lowest current Linux consumption rate among the reviewed eight-vCPU control candidates `Standard_D8as_v6`, `Standard_D8s_v6`, `Standard_D8ads_v6`, and `Standard_D8ds_v6` that still proves x64 Gen2 Trusted Launch, encryption at host, and all three East US zones.
The old v5 candidates are `NotAvailableForSubscription` in East US and their family collides with the pilot supervisor, so they are no longer allowed.
The allowlist is not a live quota, availability, or price claim; selection proves capability and rate, while every capacity decision belongs to the shared allocator.

The released whole-fleet allocator in [Elastic task workers](azure-workers.md) is the single capacity authority under the shared East US 128-vCPU admission ceiling with its 64-vCPU author plan, 40-vCPU specialized envelope, and 22-vCPU shared headroom.
There is no fixed 64-vCPU validation pool, no independent validation allocation, and no quota increase in this design.
A heavy validation request reserves its complete 40-vCPU peak atomically through one `capacity-reserve-shape` call before the 8-vCPU control cell starts: one reviewed eight-vCPU control constituent plus eight separate four-vCPU shard constituents with exact SKU, family, and cushioned worst-case cost identities.
Shard constituents never use the selected control family, so the complete shape fits the exact 10-vCPU families.
If any constituent fails regional, exact-family, specialized-envelope, or budget admission, no constituent is reserved and the complete request stays durably queued with the exact refusal.
Child runner VMs re-admit their exact pre-reserved constituent ids idempotently through the same allocator, so their live processors are covered once without double-counting, and each child's exact first-day cost bound may re-admit at or below its cushioned constituent amount.
An explicit purge of a failed-retained cell first releases its sealed remaining constituents, then atomically retires the exact validation fence in the shared allocator. Retirement holds the allocator admission lock across a fresh entire-ledger and provider-inventory zero proof and the durable tombstone save; every later single or shape reserve on that fence refuses. Retained disk, private container, RBAC, and identity deletion begins only after that permanent barrier succeeds, including on retries after a crash.
The one-shot runner independently refuses any child beyond the parent's reserved shard slots.
An author worker must match the foundation's exact general-worker resource class before its processor count is trusted.
Quota is only a live upper bound and never turns into a warm allocation.

The default active-cell record ceiling is eight, but complete-shape processor reservation, exact-family quota, regional free quota, shared author/review demand, and current runner inventory impose the lower effective ceiling.
`FM_AZURE_VALIDATION_MAX_ACTIVE` accepts only 1 through 8.
The obsolete `FM_AZURE_VALIDATION_RESERVED_VCPUS` fixed-pool setting is rejected rather than silently reviving a separate partition.
An optional owner-only `$FM_HOME/config/azure-validation-classes.json` policy binds repository slugs to `validation-heavy` or `validation-standard`; an explicit submit class must match the project policy instead of overriding it.
The policy schema is `fm.azure-validation-classes/v1` with a `default` class and a `projects` object keyed by `owner/repository`.
Saturation leaves requests queued instead of oversubscribing a host or silently falling back to the Mac.

The commissioning cost ceiling remains $1,500, while normal admission uses the $1,000 target; both are enforced by the shared allocator's cumulative actual-plus-forecast-plus-reservations admission, not by a validation-local cost model.
Every shape constituent carries a cushioned 24-hour worst-case amount, and each admitted shard's runner then proves its own exact first-day bound against that constituent while omitting only the parent cell's already-accounted shared foundation reserve.
A new request reserves the complete control-plus-shard lifetime rather than one control VM-hour stream; the retired validation-local worker-hour planning budget has no successor because the shared allocator's budget admission owns cost pressure.
Unreadable cost, forecast, rate, usage, queue, or quota state fails closed.
Budget pressure stops only new admission and never terminates active work, a pending decision, an uncollected result, or retained recovery storage.

Cells and shard VMs are created only on demand.
A safely closed run deletes its control VM, Managed Run Command, NIC, OS disk, worktree disk, private cell container, direct role assignments, and cell identity after collecting the exact report and evidence.
The expected idle VM count is zero.

## Run identity

The canonical request schema is `fm.azure-validation/v1`.
Its digest binds all of these identities before queueing:

- A SHA-256 binding of the canonical local `FM_HOME` path without sending that path to Azure.
- Task id and task generation.
- Validation generation.
- Foundation deployment generation.
- Cell id and random fence.
- Exact GitHub repository, named branch, pushed head, tree, and Git-bundle digest.
- Exact deterministic control VM, plain private worktree disk, cell identity, and private-container resource bindings.
- Captain intent passed unchanged to no-mistakes.
- Resource class, resource limits, and requested shard count.
- Secret-free credential descriptor plus the exact persistent auth-home and injected GitHub-token paths.
- Credential-free runtime bundle manifest and digest.
- Per-cell protected owner-decision public key, key id, protocol schemas, and exact no-mistakes source commit.
- Trusted guest and shard-bridge digests.

Azure tags repeat the non-secret home, task, generation, validation, cell, fence, branch, head, worktree, SKU-family, processor-reservation, and cost-attribution bindings.
The host records every resource id, every ETag Azure returns, VM instance id, NIC `resourceGuid`, disk `uniqueId`, identity client/principal id, and guest boot id before accepting a result or deleting anything.
Where Azure returns an ETag, it guards the current mutation, while stable VM/NIC/disk identities remain authoritative across legitimate attach, detach, and power-state ETag changes.
Managed-disk GETs can omit an ETag from both the body and response headers, so the disk `uniqueId` is stored in the identity record's `etag` compatibility field and sent through the existing `If-Match` deletion path.
The pinned Azure Compute [`2023-10-02` Disk Delete contract](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/compute/resource-manager/Microsoft.Compute/Compute/stable/2023-10-02/disk.json) declares no `If-Match` parameter, so this fallback is a stable identity pin and not a claim of provider-enforced atomic ETag compare-and-swap.
A successful delete with that extra header proves only that Azure accepted the request, not that it compared the value instead of ignoring it.
The guest independently re-reads IMDS and requires the exact VM instance plus worktree disk id before mounting the private ext4 volume.
The worktree disk unique id is retained in durable run identity and repeated in every result.

A result schema `fm.azure-validation-result/v1` repeats the home, task, task generation, validation generation, cell, fence, branch, submitted head, current head, remote head, worktree disk, no-mistakes run, VM, instance, and boot identities.
Protected results additionally repeat the key id, repository id, public-key/run-bound genesis, final signed history head, and exact no-mistakes source commit.
A passed result additionally requires a full PR URL, CI-green marker, exact remote-current head, and the complete independent behavior-shard receipt set.
The guest enforces the receipt *count* before it assembles the result: a `passed` or `checks-passed` run whose receipt count does not match the requested shard count, or whose count cannot be read as an integer at either end, is demoted to `failed` in the cell with the expected and observed values in the report.
The controller's own receipt gate is wider, covering receipt shape, per-shard independence, round, head ancestry, and tree, and it stays the authority for all of those; the guest replicates only the count.
Receipts are run-scoped, not attempt-scoped: the in-cell bridge writes them in the attempt whose test step executes. A legacy reattach continues that run, while a protected signed response resumes inside the original attempt and Run Command; neither re-executes an already-green test step, so the round's receipts on the durable shard exchange survive into the final result.
Only a start boot - a fresh run - begins from no receipts.
An earlier per-attempt wipe made every multi-attempt run assemble its final result with zero receipts and demote to failed, which is exactly the stranding the demotion was built to make legible; binding safety stays with the controller gate, which accepts a receipt head only as the published head or a verified ancestor with its tree bound.
What the demotion buys is legibility, not storage. A result refused as malformed never reaches `collected`, so the reason lives only in a controller error about a malformed field; `retain-failure` still accepts a `result-published` cell and still strips its compute either way.
The worktree disk is retained for a `failed` outcome by design, and `close` is the only path that deletes it, so a demoted cell keeps its disk exactly as a refused one did.
Wrong-head, wrong-run, wrong-disk, wrong-VM, wrong-boot, stale, partial, or malformed results are retained and refused.

## Persistent auth home and expiry

The `fm-auth-home` Azure Files share is exactly one home-shaped tree, not a profile pool.
The guest's `auth_home_pull` copies the whole share into one cell home and then exports `CODEX_HOME=$HOME/.codex` or `CLAUDE_CONFIG_DIR=$HOME/.claude`, so the only paths any consumer reads are `.codex/auth.json` and `.claude/.credentials.json`.
Azure Crosscheck reviewers never read the share at all; they receive a per-review credential archive.
A multi-profile layout has no consumer and is not created.

`bin/fm-credential-expiry.py` owns the question of whether one local account profile's credential is usable, and until when.
It classifies a profile as `usable`, `refreshable`, `expired`, or `unusable` from the provider's own credential file, never emits token material, and never logs in or refreshes.
`refreshable` means the access token is dead but refresh material survives; firstmate has no token refresh anywhere, so only an interactive login, or the provider CLI reaching its own auth host from wherever the profile runs, turns `refreshable` into `usable`.

`bin/fm-azure-validation.sh auth-seed` publishes a locally re-authenticated credential onto the share, so an operator can replace a dead share credential without waiting for a cell to fail on it.
It gates what goes onto the share, not what comes off it: `dispatch_cell` does not re-check the share before creating a cell, so a credential that expires between seedings still reaches a booted cell.
It plans locally with no Azure call, refuses any profile that is not `usable`, uploads only the credential file into the layout above, and re-reads the share to prove the exact byte count landed.
`--apply` additionally requires `--confirm-seed` and the exact `--confirm-subscription`.

The clean-shutdown `auth_home_push` is the only write-back.
A pull now leaves a durable `auth-push-owed` marker on the worktree disk naming where the cell's credential actually came from, a failed push leaves `auth-push-failed`, and a successful push clears both.
Because a successful push clears the owed marker, an earlier skipped write-back is reported only while the share is still stale, which is the window in which it matters.
Every marker write is best-effort: the guest runs under `set -euo pipefail`, and a note to the operator must never abort a run that has already been paid for.
The cell report surfaces the surviving marker the same way it surfaces `auth-needed`, so a stale share is an operator signal rather than a stderr line that died with the guest.

## Credential descriptor and injection

The secret-free `fm.azure-validation-credentials/v1` descriptor names one verified provider, one home-shaped local auth directory, and one GitHub token file.
Provider credentials are packed only into the private input object and overlaid by the `fm-auth-home` share on boot.
The GitHub token is read at dispatch and supplied only through the Managed Run Command protected-parameter collection.
Neither credential value enters request JSON, local state JSON, Azure tags, runtime manifests, reports, or shard requests.
The guest writes the token to an owner-only file, configures a repository-local credential helper that reads only that file, and never prints the token.

## Runtime bundle

The cell image is pinned Ubuntu 24.04, but no ambient installed provider or no-mistakes version is trusted.
Submission requires a credential-free `runtime.tar.gz` with a `runtime.json` manifest using schema `fm.azure-validation-runtime/v1`.
The manifest binds the exact provider, no-mistakes semantic version and 40-hex source commit, protected owner-decision protocol, fixed executable paths, bundled Node interpreter, fixed `gh-axi` wrapper and `gh-axi/dist/bin/gh-axi.js` entrypoint, the producer-recomputed reachable package/module closure, and SHA-256 digest of every regular runtime file. Before starting a run, the guest also executes the sealed no-mistakes artifact's bounded `--version` probe and requires both the manifest version and the exact full source revision.
Its JSON is recursively duplicate-key-free, and its root fields and every `{path,digest}` file record are closed schemas; duplicate or unknown fields, including token- or secret-named additions, are refused before anything can persist into `request.runtime`.
Every declared executable must carry the expected basename and executable mode.
The outer bundle and every producer input must be a regular file with exactly one filesystem link.
One normalized case-insensitive credential policy covers producer source paths, archive destinations, submit members, manifest records, and the guest inventory.
It rejects provider and tool homes (`.codex`, `.claude`, `.azure`, `.ssh`, `.docker`, `.config/gh`), common stores (`.git-credentials`, `.npmrc`, `.pypirc`, `.env`, `.netrc`, auth/cookie/credential files), private-key material, and access-token, refresh-token, client-secret, private-key, API-key, password/passwd/passphrase, token, secret, and equivalent separator/case/CamelCase/adjacent-acronym variants anywhere in a non-code basename. A compact matcher is suffix-only, so source-code names such as `secret.js` and non-sensitive words such as `tokenizer.json`, `passwordless.json`, `secretary.json`, or `author.json` remain valid.
The bundle also rejects archive links, devices, escaping paths, files over 512 MiB, and total size over 1 GiB.
The guest first requires the extracted manifest to equal the sealed `request.runtime`, then re-verifies the closed schema, fixed paths, wrapper, entrypoint, closure members, normalized credential policy, complete file inventory, and every digest before execution.

Every producer and submit source path is checked both lexically and canonically for credential provenance, then opened component by component with no-follow directory descriptors; a safe-looking alias through any symlinked parent is refused.
Submit first copies the resulting identity-pinned operator descriptor into a mode-0700 private staging directory.
It validates and hashes only those staged bytes, then makes the payload copy through the same one-link/no-follow contract and rehashes that copy against the request digest.
Changing the operator path after staging therefore cannot change the validated or queued runtime, while an outer symlink, hardlink, in-place mutation during staging, or changed payload copy fails closed.

`bin/fm-azure-validation.sh build-runtime-bundle` builds this archive from explicit operator-supplied artifacts and never downloads or installs anything.
The operator supplies statically linked Linux x86-64 `no-mistakes`, provider, provider-extra, and `gh` artifacts, an explicit Linux x86-64 Node interpreter, plus a prepared production `gh-axi` package tree containing `dist/bin/gh-axi.js` and its pruned production `node_modules`.
Codex bundles must include a provider-extra named `codex-code-mode-host`.
The producer and submission validator both validate the `gh-axi` package manifest, fixed bin binding, reachable relative JavaScript imports, package exports, and required production dependency and peer-dependency closure without executing host or target code; the exact sorted closure is sealed into the manifest for the guest.
The producer checks every supplied native artifact, including Node, for executable mode, 64-bit little-endian ELF identity, and the x86-64 machine id before a cell can be billed for a wrong-platform runtime.
The generated `gh-axi` wrapper invokes only the manifest-bound `bin/node`; it never resolves an ambient image interpreter.
The submission validator independently requires `node_path == "bin/node"`, `gh_axi_path == "bin/gh-axi"`, that Node member to be a Linux x86-64 ELF, and the wrapper to match the exact generated bytes, so an alternate ELF cannot hide an ambient `bin/node` shim and a hand-edited archive cannot redirect either executable.
The explicit `--no-mistakes-version` must be the exact output provenance of running the supplied artifact's `no-mistakes --version` on Linux.
The producer refuses links, non-regular inputs, credential-like paths, unsafe or duplicate destinations, existing output files, and every validator size or inventory violation it can establish before archive creation.
It emits `runtime.json` first, then sorted regular-file members with no directory members, uid and gid zero, mtime zero, and modes normalized to 0644 or 0755.
It writes deterministic PAX tar bytes through gzip with mtime zero to a same-directory per-invocation staging file, calls the submission validator on that temporary archive, compares the validated manifest to the one it built, then atomically links the completed file into the previously absent output name and prints its SHA-256 digest.
It never replaces an existing output.

Build a bundle without Azure access:

```sh
bin/fm-azure-validation.sh build-runtime-bundle \
  --provider codex \
  --no-mistakes '<linux-x86-64-no-mistakes>' \
  --provider-binary '<linux-x86-64-codex>' \
  --provider-extra '<linux-x86-64-codex-code-mode-host>' \
  --gh '<linux-x86-64-gh>' \
  --node '<linux-x86-64-node>' \
  --gh-axi-package '<prepared-gh-axi-package-directory>' \
  --no-mistakes-version '<exact-no-mistakes-version>' \
  --no-mistakes-source-commit '<exact-40-hex-source-commit>' \
  --output '<runtime.tar.gz>'
```

A minimal manifest shape is:

```json
{
  "schema": "fm.azure-validation-runtime/v1",
  "provider": "codex",
  "no_mistakes_version": "1.41.2",
  "no_mistakes_source_commit": "<40 hex>",
  "owner_decision_protocol": "fm.azure-validation-owner-decision/v1",
  "no_mistakes_path": "bin/no-mistakes",
  "provider_path": "bin/codex",
  "gh_path": "bin/gh",
  "node_path": "bin/node",
  "gh_axi_path": "bin/gh-axi",
  "gh_axi_entrypoint": "gh-axi/dist/bin/gh-axi.js",
  "gh_axi_closure": [
    "gh-axi/dist/bin/gh-axi.js",
    "gh-axi/package.json"
  ],
  "files": [
    {"path": "bin/no-mistakes", "digest": "sha256:<64 hex>"},
    {"path": "bin/codex", "digest": "sha256:<64 hex>"},
    {"path": "bin/codex-code-mode-host", "digest": "sha256:<64 hex>"},
    {"path": "bin/gh", "digest": "sha256:<64 hex>"},
    {"path": "bin/node", "digest": "sha256:<64 hex>"},
    {"path": "bin/gh-axi", "digest": "sha256:<64 hex>"},
    {"path": "gh-axi/dist/bin/gh-axi.js", "digest": "sha256:<64 hex>"},
    {"path": "gh-axi/package.json", "digest": "sha256:<64 hex>"}
  ]
}
```

The runtime bundle is code, not a credential transport.
Credential renewal or login is never performed by the dispatcher.

## Cell process and storage isolation

The cell template has no public IP, password, SSH key, inbound listener, load balancer, or public storage path.
It installs both a guest shutdown timer and an independently inventoried Azure-native `ComputeVmShutdownTask`; cleanup retains that schedule until exact VM absence and detached disposable capacity are proven.
It uses the foundation's private `snet-validation` subnet, isolated NSG, NAT egress, a disposable OS disk, and a retained private worktree disk.
The VM receives one user-assigned identity created for that cell.
That identity and the exact local operator receive Blob Data Contributor only on the cell's unique private container.
The identity receives no subscription, resource-group, VM, network, Key Vault, sibling-container, or general validation-shards authority.

The guest creates a fresh ext4 worktree volume only for a start boot or opens the exact retained ext4 volume for a legacy reattach.
No-mistakes state, SQLite database, repository, temp, cache, logs, evidence, report, and shard exchange live on the worktree volume.
A legacy replacement VM attaches that same volume; protected owner-decision runs refuse VM or daemon replacement.
The provider home is overlaid from the dedicated auth share, and the GitHub token exists only in the guest's owner-only token file.

No-mistakes runs under one transient systemd cgroup with a 700-percent CPU cap, class-specific memory maximum, zero swap, bounded tasks, bounded wall time, control-group kill mode, private temp/devices, no new privileges, strict system/home/kernel/control-group protection, empty capability bounding set, and a cell-specific writable-path allowlist.
The no-mistakes database and daemon never share a restart boundary or connection with another cell or local home.
Stopping or losing one VM cannot stop a peer cell, shard VM, local supervisor, author worker, or legacy daemon.

## True behavior sharding

The trusted default-branch `.no-mistakes.yaml` preserves the ordinary local commands outside a validation cell.
Inside a cell it invokes only the root-owned shard bridge for lint and tests.
A worktree branch cannot replace that absolute bridge path.
The bridge parses duration inventory and returned manifests as data and reproduces the existing deterministic LPT planning/completeness contract internally; it never executes a worktree verifier while provider or GitHub credentials are mounted.

For behavior parallelism, the bridge creates one exact clean Git bundle and eight `fm.azure-validation-shard/v1` requests.
Each request binds the cell, round, shard index/count, branch, current head, tree, bundle, fixed command, command digest, and declared manifest artifact.
The fixed behavior command is the existing sealed `bin/fm-behavior-shards.sh --run <N> 8` route with the explicit Azure/Linux non-Herdr selection already used by isolated CI.
It also carries the cell's own host-capability declaration, `FM_TEST_HOST_CAPABILITIES_ABSENT`, naming by name the four sealed-suite capabilities a shard worker cannot provide: a real tmux server it can create windows in, passwordless sudo with `systemd-run`, the `/usr/bin/cpp` binding `bin/fm-account-directory.sh` needs before it can validate a Claude quota-axi Keychain approval marker, and outbound reach to the origin remote's host (`origin-egress`).
Be exact about what the fourth one costs, because it is much the largest and a skip must never read as coverage.
The runner unit that executes these shards sets `PrivateNetwork=yes`, `RestrictAddressFamilies=AF_UNIX` and `IPAddressDeny=any`, so `bin/fm-teardown.sh`'s secondmate upstream-authority probe can never resolve or reach the origin host, and `origin-egress` therefore skips THIRTY-THREE units - the whole secondmate teardown/retirement family in `tests/fm-teardown-suite.sh`.
The cell verifies none of that family: not the landed-work refusals, not the registry locking, not the network-authority pinning, not the child quiescence ordering.
That coverage lives on macOS and in CI, which is where any change to `bin/fm-teardown.sh` must be proven.
The set was enumerated to convergence rather than sampled: both teardown files run to completion with the network off, 143 of 143 cases, and `docs/azure-requirements.md` R4 owns the full account.
Each name turns the exact units bound to it in `tests/host-capabilities.tsv` into a loud `FM_HOST_CAPABILITY_SKIP` line and leaves every other unit running; `bin/fm-azure-validation.py` pins the same constant and refuses any behavior shard command that differs, and no host outside the cell is affected.
The declaration is a claim the environment makes about itself, never a probe of the capability, and `tests/host-capability-gate.sh` refuses it outright on Darwin: on a Mac these units always run, so a broken Mac goes red instead of quiet.
The local dispatcher downloads only that credential-free bundle, materializes a temporary Git checkout, and prepares one existing Azure runner invocation per shard.
It does not run the command locally.

The dispatcher assigns each shard the exact SKU and pre-reserved constituent id from the admitted shape plan, avoiding the control cell's family, and sets the runner concurrency ceiling to eight.
Each request uses the runner's exact private-parent snapshot mode, so a pipeline-owned fix commit can run before the no-mistakes push step without executing locally or prematurely mutating the remote task branch.
The one-ref Git bundle, current source ref/head/tree, digest, size, and private input blob are all bound to the parent cell and command request, while the runner independently re-proves the public trusted default base.
This parent-bound shard mode remains distinct from the direct per-run no-mistakes bundle in `docs/azure-runner.md`, which must not claim or require validation-cell capacity.
A new child starts through `runner run` with an explicit invocation, confirmation, source ref, private bundle, and parent-cell reservation; only an already recorded child uses `runner resume`, so a missing VM cannot turn a prepared record into duplicate execution.
The one-shot runner still re-proves live family quota, regional quota, rate, budget, private network, image, command bounds, and global admission under its own contract.
Every shard therefore receives a separate VM, OS disk, process namespace, port space, lock space, temp root, terminal-server space, boot id, and VM instance id.

The dispatcher downloads each runner's digest-bound private archive over the private endpoint, matches it to the bounded control-plane result, and returns one `fm.azure-validation-shard-result/v1` object per request.
The response repeats exact request, source head/tree, command, invocation, VM, boot, artifact digest/size, duration, and cost identity.
The in-cell bridge verifies every request/head/command/artifact identity, requires a distinct invocation, VM instance, and boot for every shard, reconstructs the eight executed manifests, and applies the trusted data-only completeness verifier in the control cell.
No behavior test process runs in the credentialed cell or on the Mac.
A missing, duplicate, failed, wrong-head, wrong-command, reused-boot, or reused-VM shard fails the no-mistakes test step with exact failure attribution.

The same bridge sends lint through one identity-less runner VM.
Repository command children receive no provider home, GitHub token, cell identity capability, control home, or sibling staging path.

## Queue and admission

`submit` proves a clean named branch whose exact head is already present at `origin`, validates the lease/runtime boundaries, binds deterministic resource ids from the exact configured subscription/resource-group/naming prefix, creates a Git bundle, and writes one atomic mode-0600 queue record under `$FM_HOME/state/azure-validation`.
It requires those identity values but does not contact Azure or run a repository command.
The default local queue depth bound is 128.

`dispatch` requires `--confirm-dispatch` and an exact subscription confirmation.
Before creating capacity it proves the tenant/subscription, the released runner's exact private foundation and controller-identity contract, its own cell subnet, and a live-capable reviewed control SKU, then hands the complete shape to the released shared allocator, whose atomic admission owns the shared East US 128-vCPU admission ceiling, exact-family arithmetic, the 40-vCPU specialized envelope, and cumulative actual/forecast budget pressure.
A renewable blob lease in `validation-shards/validation-cells/admission.lock` still serializes count-and-create dispatch across Firstmate homes; it is a mutual-exclusion lock only, never a capacity authority.
The lease is rechecked immediately before the cell starts.

A saturated request remains `queued`.
The dispatcher does not spin, overcommit, evict active work, change the ambient Azure subscription, request quota, register a provider, create a support ticket, buy a support plan, weaken network policy, or fall back to local validation.

## Submit and operate

Set the already reviewed foundation values from [`docs/azure-pilot.md`](azure-pilot.md).

Queue without Azure mutation:

```sh
bin/fm-azure-validation.sh submit \
  --task '<task-id>' \
  --task-generation '<task-generation>' \
  --validation-generation '<validation-generation>' \
  --intent-file '<intent.txt>' \
  --credential-lease '<credentials.json>' \
  --runtime-bundle '<runtime.tar.gz>' \
  --owner-decision-signer '<host-no-mistakes>' \
  --resource-class validation-heavy \
  --repo '<exact task worktree>'
```

Inspect the queue:

```sh
bin/fm-azure-validation.sh queue
bin/fm-azure-validation.sh status --cell '<azv-id>'
```

After explicit approval, admit one queued request:

```sh
bin/fm-azure-validation.sh dispatch \
  --confirm-dispatch \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

Drive pending shard requests without executing them locally, then observe and collect.
The long child-VM wait owns a separate shard-driver lock and never holds the cell-state lock, so status, observation, and ask-user response access stay bounded while shards run:

```sh
bin/fm-azure-validation.sh drive --cell '<azv-id>' --wait-seconds 60
bin/fm-azure-validation.sh observe --cell '<azv-id>'
bin/fm-azure-validation.sh collect --cell '<azv-id>'
```

Each submission also requires a host-native no-mistakes binary built from the same reviewed source revision as the Linux runtime:

```sh
bin/fm-azure-validation.sh submit \
  ... \
  --owner-decision-signer '<host-no-mistakes>'
```

Submission copies that signer into an owner-only per-cell directory, creates a fresh Ed25519 key pair there, and seals only the public key and key id into the request.
Before key generation and every signature, the copied signer must report the manifest's exact semantic version and full 40-hex source commit; its complete bytes and reported version remain pinned in controller state.
The private key never enters the VM, runtime archive, storage container, state JSON, logs, or Azure parameters.

When no-mistakes parks at a protected ask-user gate, the still-running guest exports the daemon's exact canonical challenge and publishes it create-only under the current attempt.
`drive` validates the immutable run, repository, submitted head, current gate head, round, findings digest, prior controller history, nonce, and bounded lifetime before exposing `needs-decision`.
Write the exact response as nonblank option/value lines in an owner-only file:

```sh
bin/fm-azure-validation.sh respond \
  --cell '<azv-id>' \
  --response-file '<response.txt>'
```

Allowed actions are `approve`, `fix`, and `skip`; `fix` may add `--findings`, `--instructions`, or one `--add-finding` JSON object.
`--yes`, step overrides, duplicate options, and unsigned responses are refused.
The response command proves the exact original Managed Run Command is still `Running` with unchanged source bytes, ordinary parameters, protected-parameter names, tags, VM identity, and attempt both before and after offline signing.
It durably retains the independently derived next history head before publishing the create-only signed envelope.
The same no-mistakes daemon verifies and appends that envelope before resuming the same run; no second Run Command or new intent exists. The controller keeps the envelope pending until either a successor challenge or the terminal protected result acknowledges its history head.
A controller crash can delay or terminally fail the cell, but cannot roll the retained history head back after the daemon consumed a decision. If the exact terminal daemon history instead proves that the envelope was never appended, a non-success result restores the prior head, records the signed envelope as abandoned, and remains collectible; that envelope and key can never authorize another run.
An unanswered challenge expires in the same attempt as an explicit terminal failure and is never converted into a cross-attempt response opportunity.

After an exact passed result is collected and the remote branch still resolves to the result head, close with that explicit head:

```sh
bin/fm-azure-validation.sh close \
  --cell '<azv-id>' \
  --confirm-close \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID" \
  --confirm-head '<exact validated head>'
```

## Failure and replacement

A missing pane, terminal, process, Run Command, or VM never authorizes a duplicate no-mistakes run.
Protected owner-decision runs categorically refuse `replace`: moving a protected database to another daemon requires a fresh signed recovery checkpoint, and Azure validation intentionally does not expose that recovery path.
The exact cell must instead finish in its original Managed Run Command or fail-retained and purge.

Legacy cells created before protected owner decisions retain their prior replacement contract.
`replace` first requires an exact Azure inventory to prove the old VM absent, the retained worktree disk present with its recorded id and ETag, and a recoverable legacy phase.
It creates a new fenced VM/boot attempt but reuses the same cell identity, private container, worktree, no-mistakes home/database, task, branch, and validation generation.

The runtime and shard bridge live on the disposable OS disk, so a retained-run replacement hydrates them before reattach.
A separate current-controller Run Command reads only the original private input object, verifies its original input and request digests, every sealed artifact digest, the new VM identity, and the retained worktree-disk binding, then restores only the exact runtime and shard bridge under `/opt`.
The controller requires one digest-complete hydration marker before it launches the cell's unchanged digest-sealed guest.
Hydration never replaces the retained repository, no-mistakes database, or agent home, and replacement remains `reattach`; it does not submit fresh intent or restart the test run.

The legacy replacement guest refuses unless the retained identity file matches the request, branch, current head, worktree disk, and exact no-mistakes run id.
It then requires `no-mistakes axi status` from the retained database to contain that exact run id before invoking `no-mistakes axi run` without an intent.
A missing or ambiguous proof retains both disks and starts nothing.

Replace only after the old VM is independently known absent:

```sh
bin/fm-azure-validation.sh replace \
  --cell '<azv-id>' \
  --confirm-replace \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

If a run fails or its result is ambiguous, remove only its exact disposable compute while retaining the private worktree, private container, and evidence for diagnosis.
The retained transition is published only after the worktree disk is present, stably identical, and detached from the removed VM:

```sh
bin/fm-azure-validation.sh retain-failure \
  --cell '<azv-id>' \
  --confirm-retain \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

No ordinary failure path deletes a worktree disk, private container, or result object.
`retain-failure` deletes the local private signing key after compute is absent because a failed-retained protected run can never respond or replace.
No command names or deletes a resource group, subnet, foundation identity, another cell, another shard, another task prefix, or a local daemon.

### Explicit retained-failure purge

`purge-retained` is the deliberate, irreversible exception for a failed cell whose retained diagnosis is no longer needed.
It accepts only `failed-retained`, its own resumable `purging` phase, or the terminal `purged` tombstone.
The operator must repeat the exact subscription, cell, and request digest in addition to the destructive confirmation:

```sh
bin/fm-azure-validation.sh purge-retained \
  --cell '<azv-id>' \
  --confirm-purge \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID" \
  --confirm-cell '<same-azv-id>' \
  --confirm-request-digest '<sha256:exact-request-digest>'
```

The command acquires the cell's shard-driver lock before its cell-state lock, so it cannot purge while the same cell is driving child invocations.
Before any destructive call, it proves the control VM, NIC, OS disk, Run Commands, and shutdown schedule absent.
It also reads every runner state owned by the cell, requires every retry lineage to be terminal with Azure compute absent, and requires every dispatched reservation to carry a durable released receipt.
Every control and shard constituent must still have the exact durable allocator id, fence, shape, SKU, family, vCPU, and cost identity recorded at admission.
The allocator's entire exact-fence ledger must be inside the sealed control, planned-root, and runner-state census; any outside row refuses before the purge plan is sealed, regardless of release status, provider inactivity, or recorded workload role.
The pinned shared-provider inventory must show every exact censused reservation inactive or absent with matching SKU, family, vCPU, and cost identity; a provider-active exact id, including one hidden behind a stale released allocator row, refuses.
Because provider inventory is not fence-bound, any provider-active id without an exact controller reservation also refuses; an unrelated active reservation is ignored only when its controller record proves a different fence.
An already-released exact constituent is accepted with its cleanup receipt, while any admitted constituent with no dispatch lineage and a queued or reserved status is listed separately for exact release.

It then proves the worktree disk is detached with its recorded stable identity under the managed-disk limitation above, requiring both the single-owner `managedBy` field and the shared-disk `managedByExtended` attachment list to be empty.
It proves the private container and its complete two-role inventory, and proves the cell identity has only its exact container and auth-share grants.
Those identities, every verified shard lineage, and only the remaining capacity constituents are sealed into an immutable purge plan.
The state durably enters non-replaceable `purging` with the plan digest before the first deletion.
Any remaining exact capacity constituent is released first and then read back as durably released and provider-inactive or absent before the retained disk, RBAC, container, or identity is touched.
Every retry repeats the complete fresh allocator/provider census before attempting a remaining release, and the census is repeated after release before artifact deletion, so a new same-fence reservation can never fall outside the sealed plan.

Retries never rebuild or widen that plan.
They accept only remaining subsets of its disk, role, container, identity, and capacity identities, use the stored mutation identities through the existing deletion-header path, and persist progress after every boundary.
A partial or ambiguous attempt remains `purging`; `replace` and `retain-failure` cannot reclaim it.
Completion retains the local state as a `purged` tombstone with the immutable plan and digest, and repeating the exact command is a no-op.

## Cleanup order

Successful close occurs only after complete result/report/evidence collection, CI-green proof, exact remote-current head proof, and explicit head confirmation.
It removes resources in this exact scope and order:

1. Every recorded validation Managed Run Command plus the guest safety Run Command.
2. The exact cell VM.
3. The exact NIC.
4. The disposable OS disk.
5. The Azure-native shutdown schedule, only after exact VM/NIC/OS-disk absence.
6. The exact private worktree disk.
7. The exact direct role assignments on the cell's private container and auth-share scope after proving their complete principal and role inventory.
8. The exact private container.
9. The exact cell identity.
10. The owner-only local signing key and transient payloads after the durable result is retained.

Before role or container mutation, close persists the exact container ETag and direct role-assignment ids.
A retry accepts only the remaining subset of that plan, so a crash between role removal, container removal, and identity removal resumes idempotently instead of requiring deleted authority to reappear.
A missing ETag, changed instance, foreign tag, foreign principal, extra role assignment, partial delete, unreadable absence, wrong head, failed run, pending decision, or incomplete result changes the state to retained cleanup and stops.

## Live acceptance

Focused fake-cloud and static tests do not claim real Azure usability.
The first live Stage C pipeline acceptance has occurred, as described in the Live acceptance record section, while the full multi-leg acceptance checklist below remains unperformed.
The separate direct per-run runner repair is not accepted by those cell results and remains blocked until its exact code lands on public `main` and a fresh routed no-mistakes run passes on real Azure compute with zero cleanup.
After this stack is released to public main and the operator has explicit billable authorization, the full checklist acceptance must run from that released main and record all of these results:

1. Record Mac wall time, CPU, memory, swap, process count, and interactive latency before admission.
2. Queue more work than the configured processor/concurrency limit and prove saturation remains queued with no oversubscription.
3. Admit multiple no-mistakes runs concurrently and prove bounded status responses without the previous shared singleton timeout.
4. Prove every run has a different daemon home, database, temp root, cache root, VM instance, boot, worktree disk, container, signing key, and cgroup.
5. Run all eight behavior shards on eight separate Azure VMs and prove every manifest passes the existing completeness guard without the documented single-host lock or SIGKILL failure.
6. Include positive liveness controls for every cell and shard while active.
7. Kill one exact cell VM and prove peer cells, all shard VMs, the local supervisor, and an unrelated local task remain healthy.
8. Prove a protected run refuses VM/daemon replacement before cleanup or new allocation, then retire it through the retained-failure purge path.
9. Submit wrong head, run id, request digest, worktree disk, owner-decision history, VM instance, boot id, and shard receipt fixtures and prove every one refuses.
10. Drive actual-cost, forecast-cost, active-cell, shared author/review demand, regional-quota, and family-quota saturation and prove each blocks only new admission; prove review demand may exceed 64 vCPUs when author demand is low but the next complete shape always queues before 128.
11. Prove no credential byte appears in snapshots, runtime bundles, result archives, state JSON, tags, ordinary ARM parameters, logs, reports, shard VMs, or uncredentialed process environments.
12. Prove one cell cannot read or write a sibling container, disk, home, or VM, and cannot apply an unsigned owner decision to its own protected daemon.
13. Prove a failed shard is attributed to its exact VM/boot/request and is never replayed locally.
14. Run a real no-mistakes pipeline through review, test, at least one pipeline-owned fix when naturally required, push, PR creation/update, CI-green return, report publication, and cleanup entirely on the Azure validation plane.
15. Prove the local supervisor remains responsive throughout the real run and has no child process for review, lint, tests, fixes, push, or CI monitoring.
16. Record before/after wall time, cell and shard queue latency, per-cell and per-shard duration, Mac and Azure CPU/memory, actual cost, estimated cost, and cleanup latency.
17. Prove every validation VM, shard VM, NIC, OS disk, worktree disk, Run Command, cell identity, role assignment, and private cell container reaches zero after safe close, and prove the local private signing key is absent.
18. Prove the Mac rollback path remains reachable.

A failed acceptance leg means Azure validation is not the default and does not authorize local fallback, weakened identity proof, shared daemon use, retained-cost deletion, or credential broadening.
The exact failed leg, retained resources, and recovery action must be reported.

## Live acceptance record

The first complete no-mistakes pipeline run inside an isolated Azure `validation-standard` cell executed on 2026-08-14 against this repository: run `01M00YX1QS5H608DPH6DFV7CDN`, validation generation `azv-stage-c-013`, lease task `azure-stage-c-validation`, task generation `spawn:558423dc544ebe5c`, validating exact head `126b60419613938c055b41447f9a65c76c31923a` through the pushed `codex/azure-stage-c-validation` branch.
Generations `azv-stage-c-014` and `azv-stage-c-015` (same head, branch, and lease coordinates) then ground-truthed the guest's outcome derivation until the authenticated result recorded that success end to end.
Those cells validated an already-merged head, so their pipeline completed at pre-push with nothing to publish; this section, submitted on the `fm/stage-c-live-acceptance` branch under the same lease coordinates in one isolated Azure `validation-standard` cell, is itself the first change validated by a cell through the full push, pull request, and CI-green proof path.
