# Azure Crosscheck isolation

This document owns the architecture, identity, network, cleanup, and operator contract for policy-grade Azure Crosscheck.
[`bin/fm-crosscheck-azure.py`](../bin/fm-crosscheck-azure.py) owns the local control adapter, [`docs/azure-crosscheck/compartment.json`](azure-crosscheck/compartment.json) owns the credentialed model VM, and the existing Crosscheck core remains the sole owner of the v2 finding ledger, readable report, and expected-head merge gate.

## Boundary

Azure Crosscheck moves only policy review from the local Mac.
Firstmate, authors, no-mistakes, browsers, and the primary supervisor remain local.
Remote Herdr is not required.

One review uses at least three fresh compartments with different immutable resource, VM, and boot identities: one model compartment plus one tool/verifier pair for every accepted evidence item.

- The credentialed model compartment receives exactly one independently selected reviewer account plus a bounded static packet containing the claims, ledger projection, and complete exact-base/exact-head diff.
- A fresh private-controller `crosscheck-tool` runner fetches the exact advertised remote PR-head ref and executes one accepted reproduction with no provider credential or repository network.
- A second newly created `crosscheck-tool` runner independently replays that accepted helper with no repository network or provider credential.

The model compartment never receives a repository checkout, dynamic repository tool, shell against the repository, Azure CLI, MCP server, extension, skill, container client, or local control authority.
Its Codex, Claude, and Pi launches explicitly disable their command tools.
The static packet is assembled from a fresh exact remote PR checkout, is byte-bounded, and is delimited as untrusted data.
The tool and verifier repository children never receive the reviewer credential, their trusted controller's storage identity/token, a GitHub credential, author worktree, control home, sibling task data, browser profile, shared temporary state, container socket, SSH agent, or machine-wide validation socket.
A single VM containing both provider credentials and repository commands is not accepted by this adapter.

The existing local review route remains available only when Azure mode is not selected.
Set `FM_CROSSCHECK_EXECUTION_MODE=azure`, or create a safe `config/crosscheck-azure.json` with `"enabled": true`, to select Azure.
A selected Azure run never falls back to the local Mac after any admission, transport, identity, tool, verifier, or cleanup failure.

## Exact identity

Every attempt binds these values into one canonical review generation:

- SHA-256 canonical `FM_HOME` binding.
- Task id and canonical PR URL.
- Exact live remote PR head.
- Reviewed merge base and observed base-branch tip.
- Stable PR claims digest.
- Reviewer harness, model, effort, and executing upstream-account digest.
- Complete pre-run v2 ledger digest.
- Deployment generation, exact model image and SKU, provider endpoint, request digest, exact credential/archive digests, and model result digest.
- Model, tool, and verifier resource IDs, immutable VM instance IDs, boot IDs, bounded result digests, source refs, and complete cleanup phases.

The exact review generation is carried in Azure tags, staged object prefixes, the model result, every command-runner request, every returned tool/verifier compartment identity, the complete evidence-attempt digest, the v2 reviewer record, and the readable report.
The reviewer-account component hashes the upstream account identity read from the exact credential, never the account-home path, because two paths may execute as one account and one path may drift to another account.
Missing or mismatched identity is a tool failure.
The merge gate revalidates the Azure identity record in addition to its existing live head, claims, durable findings, reviewer, and evidence proof checks.

A force-push changes the live head and invalidates the ordinary exact-head ledger match.
A stale claims document invalidates the claims match.
A wrong account, model, generation, VM, boot, request, transport, or cleanup identity cannot become a clear run.

## Model compartment

The model VM uses a separately built and reviewed exact Azure image resource ID supplied through `FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID`.
The image pins the supported Codex, Claude, or Pi reviewer CLI and the model guest, with no ambient credential, Azure CLI, repository helper, tool bridge, or generic command service.
No package or executable is downloaded after the VM begins review.

The reviewer credential is staged as a short-lived exact-object capability.
It exists only in the model compartment and is removed before result publication.
Claude Azure review requires a provider-supported Linux file credential.
The macOS Keychain is never copied.

The model process has no Azure CLI credential, managed identity, SSH agent, Docker socket, repository checkout, control-home mount, MCP configuration, or shell/read tool.
It reaches only the provider through the model subnet's fixed egress policy; all source metadata and exact diff content are already in its bounded prompt packet.
Reviewer-supplied helpers return only as bounded UTF-8 data and cannot execute until the trusted local controller validates them.

The compartment is bounded by a 4-vCPU/16-GiB reviewed SKU, 12-GiB process memory, zero swap, 1,024 PIDs, private temporary state, strict system/home/kernel protection, a 7,200-second maximum review deadline, a 16-MiB transcript ceiling, a 2-MiB verdict/result ceiling, and a 24-hour independent self-shutdown backstop.
The command implementation may lower these bounds but may not raise them.

## Tool and verifier compartments

The trusted host bridge consumes the existing Azure runner's exact public-source, request, result, fencing, admission, private-controller, and cleanup contracts rather than redesigning them.
The runner's explicit public-source-ref seam accepts the freshly advertised `refs/pull/<number>/head` only when it equals the reviewed SHA and refuses a later ref move.
It also binds and fetches the reviewed merge base as an exact proven ancestor so the evidence helper's exact base/head diff is available inside the otherwise shallow clean checkout.
Every accepted reproduction creates one fresh `crosscheck-tool` invocation VM in `snet-validation-shards`, and its independent replay creates a second new invocation with a different VM and boot identity.

The allow-listed repository-controlled vocabulary is one non-profile Bash helper under `.crosscheck/reproductions/`, with a bounded reviewer-supplied UTF-8 body, exact expected exit, exact output marker, and optional exact identity receipt.
For durable finding closure it also accepts a pytest mutation proof with no runner arguments after locally validating the patch applies, changes only cited non-test implementation, and leaves the named tracked test untouched.
Each remote mutation attempt creates independent clean baseline and mutated clones, requires the baseline to pass, accepts only pytest's measured test-failure exit after mutation, and refuses collection, usage, internal, or no-test exits.
The trusted replay wrapper materializes only bounded regular files below `.crosscheck/reproductions/` or `.crosscheck/mutations/`, rejects symlinks and path escapes, sanitizes the environment, bounds output, and emits only the validated receipt or a constant success marker.
No dynamic model-side read, free-form login shell, generic command launcher, arbitrary absolute path, symlink traversal, SSH, Azure CLI, container runtime, package install, background daemon interface, or mutable endpoint is exposed.
Every command child is further bounded by the `crosscheck-tool` runner class: three CPU cores, 12 GiB memory, zero swap, 1,024 PIDs, 40-GiB task filesystem, 8-MiB per-stream logs, 128-MiB artifacts, and two-hour wall time.
Repository networking is zero bytes.

Accepted evidence is replayed in a second new networkless repository child with the same exact public PR-head snapshot and accepted reproduction helpers.
The trusted private controller may use its exact container-scoped result identity only after the repository child exits; that token is never inherited by the child.
The ledger retains every tool/verifier VM, boot, request, result, cleanup, source-ref, and exact-head identity under one digest.
A verifier command failure, output overflow, identity mismatch, transport loss, or cleanup ambiguity is a tool failure and blocks merge.
A mutation runner without an Azure-measured non-execution classification remains CANNOT-CERTIFY and cannot close a durable finding.
Ambiguous result or evidence remains retained for investigation instead of being labeled clear.

## Network and cloud authority

All VMs have private NICs and no public IP, password, SSH key, public load balancer, inbound NAT, or public listener.
Azure Managed Run Command is the control transport.
The model compartment uses `snet-policy-review`.
Tool invocations use the foundation's private validation-shard contract.
The verifier attempt has no repository network and no cloud identity.

The foundation must additionally apply role-specific egress rules before live acceptance:

- Model egress permits DNS plus the exact provider endpoint and port only; it has no GitHub or repository network path.
- Tool and verifier repository execution deny all IP networking after the snapshot and fixed image closure are staged.
- Link-local metadata and Azure Instance Metadata Service are denied.
- Cross-compartment VNet, private-endpoint, control, author, validation, browser, and sibling traffic are denied.

A broad NAT route without those exact rules is not policy-grade even if the model VM itself has no managed identity.
The real acceptance inspection must prove effective NSG, guest firewall, DNS, route, and metadata behavior.

The local controller requires exact tenant, subscription, resource group, storage, VNet, private endpoint, deployment generation, SKU, quota, budget, and current-cost proofs from the accepted foundation and runner.
It never changes the ambient Azure CLI default.
It creates no role assignment, provider registration, public path, support ticket, quota request, or deployment foundation.

## Parallelism, admission, and cleanup

There is no warm review compute and no review queue daemon.
Zero waiting reviews means zero model, tool, or verifier VMs.
Review capacity is owned by the released whole-fleet allocator in [Elastic task workers](azure-workers.md): every model compartment reserves one exact SKU/family/cost constituent through `capacity-reserve` before compute and releases it only after proven compute absence, tool and verifier invocations reserve through the released runner's own shared-allocator bridge, and review demand shares the 40-vCPU specialized envelope with no-mistakes validation under the single 128-vCPU East US ceiling.
A queued shared reservation refuses the review rather than creating capacity, and the local software cap (default four active model compartments, configurable one through eight) remains only a concurrency safety bound, never a capacity authority.
Regional and exact-family quota can impose a lower effective ceiling.

Two admitted reviews have distinct review generations, staged object prefixes, model VMs, tool invocations, verifier invocations, process trees, scratch, credentials, and cleanup authorization.
They do not share a database or writable account disk.
The durable v2 per-task lock and ledger remain home-local and keep one writer per task.

Cleanup starts only after a complete digest-bound result and exact compartment identities are retained.
The controller re-reads tags and ETags before conditional deletion.
It deletes only the attempt's review and safety Managed Run Commands, model VM, NIC, OS disk, exact staged request, exact staged credential, and exact staged result.
Every conditional deletion is followed by an exact absence proof, and an authorization, transport, or inventory error remains ambiguity rather than being treated as absence.
The reused Azure runner independently performs the same identity-pinned cleanup for tool and verifier invocations.
Foreign, missing, replaced, unreadable, or partially deleted resources retain state and fail closed.
No resource group, subnet, shared storage account, foundation resource, sibling prefix, author VM, validation run, browser, supervisor, or another review can be deleted.

## Operator setup

The complete retained 29-resource private foundation, its controller-identity inventory correction, and the shared whole-fleet allocator are released on `main` with zero VMs; live Azure Crosscheck acceptance remains unperformed and happens later from released public main under separate explicit billable and security-sensitive authorization.
The pinned model image and the role-specific network policy are tracked declarations at [`docs/azure-crosscheck/model-image.json`](azure-crosscheck/model-image.json) and [`docs/azure-crosscheck/network-policy.json`](azure-crosscheck/network-policy.json), owned by the bounded command [`bin/fm-crosscheck-azure-image.sh`](../bin/fm-crosscheck-azure-image.sh).
The image pins the exact marketplace base version, the single supported reviewer CLI by URL/size/SHA-256, and the tracked model guest by SHA-256, and disables every command, MCP, extension, skill, and session surface; the policy allows model egress only to Azure-provided DNS and the exact provider endpoint, denies instance metadata and the virtual network, and keeps tool/verifier repository execution networkless.
Plan legs are read-only; `image-build` and `policy-apply` are billable/security-sensitive, refuse without their exact confirmation flags and subscription, and run only from a clean checkout landed on public main.
Record the exact built image resource ID before any live review.

The home-local configuration is optional and gitignored:

```json
{
  "enabled": true,
  "provider_host": "exact-provider-host.example",
  "provider_port": 443,
  "reviewer_sku": "Standard_D4as_v6",
  "model_image_id": "/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/images/..."
}
```

The required environment is the accepted foundation's existing `FM_HOME`, `FM_AZURE_TENANT_ID`, `FM_AZURE_SUBSCRIPTION_ID`, `FM_AZURE_NAMING_PREFIX`, `FM_AZURE_STORAGE_NAME`, `FM_AZURE_OWNER_TAG`, `FM_AZURE_DEPLOYMENT_GENERATION`, and independently accepted `FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID`, plus the exact image through the config or `FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID`.
The standard Crosscheck reviewer roster remains `config/crosscheck-reviewer.json` and keeps its existing account/model policy.

After acceptance, the operator flow remains unchanged:

```sh
bin/fm-crosscheck.sh run <task-id> <full-pr-url>
bin/fm-crosscheck.sh verify <task-id> <full-pr-url>
```

The same `data/<task-id>/crosscheck-ledger.json` and `data/<task-id>/crosscheck.md` are written.
Only the reviewer execution record gains `execution_mode: azure-compartment-v1` and the complete compartment identity.
The readable report shows the primary model/tool/verifier identities, total evidence-pair count, complete evidence-attempt digest, and cleanup state; the ledger retains every pair in full.

## Focused local verification

The implementation's deterministic checks use fake Azure/runner/model fixtures only and never create a cloud resource:

```sh
tests/run.sh tests/fm-crosscheck-azure.test.sh
bash -n bin/fm-crosscheck-azure-model-guest.sh
python3 -m py_compile bin/fm-crosscheck.py bin/fm-crosscheck-azure*.py
python3 -m json.tool docs/azure-crosscheck/compartment.json
bin/fm-lint.sh
```

This emergency lane must not invoke no-mistakes or the full repository suite locally.

## Live acceptance after exact foundation approval

Policy-grade usability remains unclaimed until the approved Azure deployment records dated Linux evidence for every leg below.
Every denied malicious probe needs an allowed positive control that proves the harness could observe the counterpart.

1. Review a real open PR from a fresh remote exact head with a model/account independent from the author.
2. Prove the model sees the allowed claims, ledger projection, complete bounded exact diff, and provider completion while it has no repository command tool and reviewer-token reads from tool/verifier are denied.
3. Prove the static packet contains the allowed exact diff and the fresh tool/verifier pair produces allowed helper output while model-side repository reads and control-home, sibling, author-worktree, browser-profile, validation socket, container socket, SSH agent, cloud metadata, private-neighbor, and network escape probes are denied.
4. Prove an allowed regular artifact and allowed in-tree path while symlink swaps, rename races, devices, FIFOs, absolute paths, parent escapes, and oversized output/artifacts are denied.
5. Prove a bounded child command while fork, daemon, detached descendant, PID, CPU, memory, disk, and wall exhaustion remain bounded and complete guest destruction removes residue.
6. Submit wrong reviewer account, model, head, base, claims digest, home, task, review generation, request digest, VM instance, boot identity, and stale endpoint/result fixtures; each must become a tool failure.
7. Run two real reviews concurrently and prove distinct accounts, model VMs, tool VMs, verifier VMs, process trees, scratch, object prefixes, ledgers, and cleanup authority with no shared residue.
8. Kill one model compartment and prove the other review, one author, one no-mistakes validation run, and the primary supervisor remain healthy.
9. Kill one tool VM and prove its review fails closed while the other review continues.
10. Replay accepted evidence in a second fresh VM with networking and credentials absent; compare output/exit digests and reject any difference.
11. Force-push the reviewed PR and prove `fm-crosscheck.sh verify` rejects the stale ledger before merge.
12. Run the merge-gate verification for the current head and prove it prints only the reviewed SHA.
13. Inspect Azure inventory after collection and prove all disposable model/tool/verifier Managed Run Commands, VMs, NICs, disks, and per-review staging objects are gone while foundation, author, validation, browser, supervisor, and other review resources are unchanged.
14. Record exact image, CLI versions, commands, VM/boot identities, NSG/route/firewall facts, cleanup inventory, Azure cost, and Mac CPU/memory/swap/process responsiveness in a dated evidence document.

Cloud-default acceptance additionally requires that the real PR's current head has a clear v2 ledger, the expected-head merge gate succeeds, and every disposable review resource is destroyed without affecting the rest of the fleet.
If any leg fails, Azure Crosscheck is not policy-grade, the PR remains unmergeable, and the local path is not an automatic fallback.

## Deliberate limits

This service does not move Firstmate, authors, no-mistakes coordination, browsers, Herdr, or general elastic workers to Azure.
It does not provide remote terminal visibility.
A later Herdr proxy may display a review, but authoritative liveness and cleanup remain the exact Azure review/VM/boot identities.

The tracked image build and live network policy must be deployed and evidenced before real acceptance.
The exact static-packet transport and host-side evidence bridge must also be exercised end to end; the model compartment may not gain Azure control authority or receive the repository as a shortcut.
The adapter deliberately refuses to infer that an arbitrary Ubuntu image contains a reviewer or tool closure.
