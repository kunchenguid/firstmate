# Azure Crosscheck isolation

> **Multi-lane reviews (2026-08-15).** Reviews run in `FM_AZURE_CROSSCHECK_LANES`
> (default 4) parallel lanes with durable FIFO queuing when all lanes are busy
> (bounded by `FM_AZURE_CROSSCHECK_QUEUE_WAIT_SECONDS`); lane index selects the
> reviewer SKU deterministically across four families unless `reviewer_sku` is
> pinned in config. `python3 bin/fm-crosscheck-azure.py lanes` lists
> queued/running per lane. Reviewers copy their credential in at boot and
> never sync it back; only the validation cell lane writes fm-auth-home.

This document owns the architecture, identity, network, cleanup, and operator contract for policy-grade Azure Crosscheck.
[`bin/fm-crosscheck-azure.py`](../bin/fm-crosscheck-azure.py) owns the local control adapter, [`docs/azure-crosscheck/compartment.json`](azure-crosscheck/compartment.json) owns the credentialed model VM, and the existing Crosscheck core remains the sole owner of the v2 finding ledger, readable report, and expected-head merge gate.

## Boundary

Azure Crosscheck moves only policy review from the local Mac.
Firstmate, authors, no-mistakes, browsers, and the primary supervisor remain local.
Remote Herdr is not required.

One review uses at least three fresh compartments with different immutable resource, VM, and boot identities: one model compartment plus one tool/verifier pair for every accepted evidence item.

- The credentialed model compartment receives exactly one independently selected reviewer account plus a bounded static packet containing the claims, ledger projection, and complete exact-base/exact-head diff.
- A fresh private-controller `crosscheck-tool` runner receives a digest-bound bundle of the authenticated exact PR-head checkout and executes one accepted reproduction with no provider credential or repository network.
- A second newly created `crosscheck-tool` runner independently replays that accepted helper with no repository network or provider credential.

The model compartment never receives a repository checkout, dynamic repository tool, shell against the repository, Azure CLI, MCP server, ambient extension, skill, container client, or local control authority.
Its only extension is the tracked digest-bound verdict submitter, which exposes no repository or command capability.
Its Codex and Pi launches explicitly disable their command tools; the interim claude launch lane is retired (R6).
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

## Reviewer credential preflight

The model compartment's egress allowlist is Azure-provided DNS plus the exact provider API endpoint, and a provider auth host is not on it.
A reviewer CLI inside the compartment therefore cannot refresh an expired session, so a dead credential buys a real VM and returns a tool failure instead of a verdict.

Every review runs `bin/fm-credential-expiry.py` against the selected reviewer's account home three times: before the FIFO lane wait, once the lane is held, and after shared capacity is admitted.
The third check gates Azure staging and compute because `FM_AZURE_CROSSCHECK_QUEUE_WAIT_SECONDS` bounds both lane and shared-capacity waiting at 7200 seconds by default and 86400 at its maximum.
The credential must be `usable` and must still be usable after the review deadline (`FM_CROSSCHECK_REVIEWER_TIMEOUT_SECONDS`); `refreshable` is refused because it is not recoverable inside the compartment.
A refusal is an ordinary tool failure, so the roster records the account and rotates to the next policy-screened reviewer rather than ending the review.
The preflight reads expiry instants and account paths only, and never emits token material.

## Model compartment

The model VM uses a separately built and reviewed exact Azure image resource ID supplied through `FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID`.
The image pins the Codex, Claude, and Pi reviewer CLIs and the model guest, with no ambient credential, Azure CLI, repository helper, tool bridge, or generic command service.
No package or executable is downloaded after the VM begins review.

The reviewer credential is staged as a short-lived exact-object capability.
It exists only in the model compartment and is removed before result publication.
The macOS Keychain is never copied.

### Cross-family primary reviewer (R6)

The primary review family is a registered cross-family lane, driven by Pi as that lane's model on its own custom provider slot.
Today's registry is the single lane `fireworks-glm`, using the regular Fireworks GLM 5.2 selector `accounts/fireworks/models/glm-5p2` through the direct Fireworks endpoint.
The historical Fast selector remains ledger-readable but is not admitted for a new review.
The Azure Foundry partner lane it replaced is unusable on this subscription: see R6 in docs/azure-requirements.md.
For that profile the packaged compartment credential is the api-key `models.json`, not a codex `auth.json`.
The credential is pinned to exactly `https://api.fireworks.ai/inference/v1` on chat completions only, and any other baseUrl refuses before staging.
The archive gate requires the exact regular-lane compat values `supportsStrictMode: true`, `sendSessionAffinityHeaders: true`, and `sessionAffinityFormat: openai`.
It also requires declared per-million rates of 1.40 dollars for input, 0.14 dollars for cached input, 1.40 dollars for cache write, and 4.40 dollars for output.
pi gives model-level `baseUrl`/`api` fields precedence over the provider level, so the inspection, the archive gate, and the model guest all refuse a model entry carrying either field; the pinned provider level owns both.
`effective_provider_host` is model-aware: a cross-family review derives its own lane's host, today `api.fireworks.ai`, as its single egress host and refuses a conflicting configured `provider_host`, while the codex-family fallback keeps its `chatgpt.com` derivation.
The executing identity is the non-secret provider-slot, endpoint, and model binding (an api key names no upstream account); the api key and anything derived from it never enter identity, ledger, or output.
The interim claude reviewer lane is retired end to end: no `api.anthropic.com` host derivation, no `.credentials.json` packaging or boot copy, and no claude launch branch in the model guest.
The request embeds the tracked verdict extension and Pi reviewer runtime with their SHA-256 digests because the model VM has no repository checkout.
The guest byte-checks both sources before writing them, then the digest-bound runtime launches Pi with `--offline`, `--no-extensions`, and the exact explicit `--extension` path and validates the terminating tool event stream.
The extension registers only `submit_crosscheck_verdict` with strict JSON-schema constrained sampling and terminates the run after the call, so no paid follow-up turn is needed.
The Pi generation schema represents `evidence_files` as bounded path/content records because strict-tool preparation does not support schema-valued object properties.
The host refuses duplicate paths, converts those records to the existing manifest dictionary, and then applies the unchanged path, content, and aggregate bounds.
The guest requires at least one turn, a final assistant `toolUse` stop, exactly one completed agent, and exactly one verdict call in the successful final attempt.
The final terminal event must report the exact `fireworks-glm` provider and `accounts/fireworks/models/glm-5p2` model selector requested by the compartment.
Reporting the historical Fast selector or another route fails before a verdict can publish.
Pi's explicit `auto_retry_start` may open a continuation only after a completed attempt executed a turn and did not stop successfully.
The continuation resets attempt-local terminal and verdict state, preserves aggregate usage for economics, and must execute its own turn before completing.
The bounded verdict-repair contract owned by [`docs/crosscheck.md`](crosscheck.md) applies unchanged inside the isolated model compartment.
The prompt is passed by `@file`, and every Pi attempt starts with `--offline` in a fresh ephemeral session with no persisted conversation.
The stable system prompt and byte-stable verdict tool schema precede all untrusted pull-request material.
The guest returns input, output, cache-read, cache-write, turn, and Pi-calculated cost data from the complete event stream when available.
The host records those values, recomputes declared regular-lane cost, keeps provider-reported cost separate, and adds reviewer latency before publishing the run.
Historical note: four live 2026-08-21 cross-family attempts for PR #285 reached model compartments but returned no valid Azure verdict.
Those failures exposed loose final-text submission, an incomplete outer wrapper, and a duplicated executing-account identity derivation.
The strict terminating verdict tool and the executing guest tests now own those regressions.
No live Azure acceptance or operator enablement is claimed by this implementation-only change.
The earlier reading of this limit said the built image carries no `pi` binary and needed a rebake. That was measured on 2026-08-16 against gallery version `1.0.1786915905`, whose source managed image `img-fm7c799d-ccm-1.0.0` was built on 2026-08-13 from the pre-Pi declaration and carries no `pi-tarball-sha256` tag (M29 in the owner's mutation ledger, `firstmate-azure-full-completion-mutation-ledger.md`, which lives outside this repository rather than in it). It was already stale when it was written here: `model_image_id` has named `1.0.1787092687` since 2026-08-18T22:45Z.
That current version was published 2026-08-18T22:38:08Z from managed image `img-fm7c799d-ccm-1.0.1787091895`, which carries `pi-tarball-sha256` `a69a1859...` and `node-tarball-sha256` `d60acfe0...`, matching `docs/azure-crosscheck/model-image-closure.json` for `pi-coding-agent` 0.84.1 and Node v22.23.2. Only a build from the Pi-carrying declaration writes those tags, its Image Builder run succeeded, and that declaration asserts `/usr/local/bin/pi --version` against the tracked version twice under `set -eu`, before and after the credential purge, so a build that reached distribution cannot have omitted `pi`. What remains unproven is a Pi review actually completing on this image, which is a separate claim from the binary being present.
Both readings were guesses about an image that admission never inspected. It does now: the harness attestation guard described under Operator setup reads `pi-tarball-sha256` and `node-tarball-sha256` off the configured image before any model VM exists, so the next time this question is asked the lane answers it from the image rather than from a document, and a wrong `model_image_id` is refused for free instead of discovered on a paid VM.
The 25K TPM quota cap (DataZoneStandard capacity 25) bounds review throughput until quota is raised.

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
A queued shared reservation caused by exact-family or shared-capacity pressure is retried with the same durable reservation identity until `FM_AZURE_CROSSCHECK_QUEUE_WAIT_SECONDS` expires, while budget, daily-bound, credential, identity, and other allocator failures remain immediate.
Timeout releases the exact queued reservation before failing, and the local software cap (default four active model compartments, configurable one through eight) remains only a concurrency safety bound, never a capacity authority.
Regional and exact-family quota can impose a lower effective ceiling.

Two admitted reviews have distinct review generations, staged object prefixes, model VMs, tool invocations, verifier invocations, process trees, scratch, credentials, and cleanup authorization.
They do not share a database or writable account disk.
The durable v2 per-task lock and ledger remain home-local and keep one writer per task.

Cleanup starts only after a complete digest-bound result and exact compartment identities are retained.
The controller persists that admitted semantic run before cleanup begins.
The record carries an explicit pending cleanup state while cleanup is in flight.
If cleanup becomes ambiguous, that state remains ledger-valid but cannot certify
the review, and the separate post-admission tool alarm exits nonzero without
launching or charging another reviewer. Bridge refusals during an individual
proof are normalized into the core evidence error family so closure and
new-finding degradation keep their item-scoped semantics.
If cleanup is ambiguous, the admitted run remains durable and a separate nonzero tool-failure alarm is appended; retrying publication or cleanup never reruns the model.
The controller re-reads tags and ETags before conditional deletion.
It deletes only the attempt's review and safety Managed Run Commands, model VM, NIC, OS disk, exact staged request, exact staged credential, and exact staged result.
Every conditional deletion is followed by an exact absence proof, and an authorization, transport, or inventory error remains ambiguity rather than being treated as absence.
The reused Azure runner independently performs the same identity-pinned cleanup for tool and verifier invocations.
Foreign, missing, replaced, unreadable, or partially deleted resources retain state and fail closed.
No resource group, subnet, shared storage account, foundation resource, sibling prefix, author VM, validation run, browser, supervisor, or another review can be deleted.

## Recorded phase durations

This lane measures the four phases only it performs into the core run record's `durations_ms` (C1, `docs/azure-requirements.md`), alongside the `reviewer` and `proofs` phases the local lane also records:

- `create`: shared-allocator capacity reservation plus model VM provisioning.
- `stage`: the credential archive, the request document, and their two blob uploads.
- `boot`: the Managed Run Command dispatch that starts the guest.
- `reviewer`: polling that run command to completion, which is the remote review itself.
- `collect`: the result download and its digest-bound parse.

Cleanup is deliberately not one of them, so `total` is larger than the sum of the named phases by the cleanup and admission time between them.
The timer is optional at this boundary: the adapter's own CLI records nothing, and nothing recorded reads as "not measured" rather than as a zero.

These phases are lane-bound in the ledger contract: they are admitted only on a run record whose reviewer entry carries `execution_mode: azure-compartment-v1`, which this adapter stamps once a review completes.
A compartment review that fails before that identity record is complete therefore cannot keep its recorded `create`/`stage` phases, and the writer drops that run's whole measurement rather than write a record every later reader would refuse.
That loses exactly the numbers a failed compartment review would be most useful for, and it is a deliberate choice over the two alternatives: bricking the task ledger, or letting any record claim compartment phases it never performed.
**This is a known gap with a follow-up that must land before any compartment timing is relied on: the lane must be stamped at its START.** It was previously described as bound to an image rebake; there is no rebake to wait for, so the follow-up is gated only on the lane being switched on.
`docs/crosscheck.md` owns that follow-up, including why stamping `execution_mode` earlier refuses the record instead of fixing it.

No accepted numbers exist yet. The four failed 2026-08-21 compartment attempts executed these phases but did not produce the complete Azure reviewer identity record this ledger boundary requires, so their measurements were discarded as described above. The operator-home file still defaults the lane off with `"enabled": false`; those live attempts used the explicit Azure execution-mode opt-in. `bin/fm-crosscheck.sh timings <task-id>` therefore still shows `-` in the `create`, `stage`, `boot`, and `collect` columns for local-lane runs, which is the honest reading: those runs did not do that work.

## Operator setup

The complete retained 29-resource private foundation, its controller-identity inventory correction, and the shared whole-fleet allocator are released on `main` with zero VMs; live Azure Crosscheck acceptance remains unperformed and happens later from released public main under separate explicit billable and security-sensitive authorization.
The pinned model image and the role-specific network policy are tracked declarations at [`docs/azure-crosscheck/model-image.json`](azure-crosscheck/model-image.json) and [`docs/azure-crosscheck/network-policy.json`](azure-crosscheck/network-policy.json), owned by the bounded command [`bin/fm-crosscheck-azure-image.sh`](../bin/fm-crosscheck-azure-image.sh).
The image pins the exact marketplace base version, the Codex and Claude reviewer CLIs by URL/size/SHA-256, and the tracked model guest by SHA-256, and disables every repository command, MCP surface, ambient extension discovery, skill, and persistent session; Pi is pinned less tightly and deliberately so: its Node runtime and its published tarball are pinned by the same URL/size/SHA-256 contract, and its installed version is asserted after the build, but `npm install` then resolves roughly 127 dependency packages over the network. Pi's own six sibling packages carry a `resolved` URL and no `integrity` hash in the shipped shrinkwrap, so a republished `@earendil-works/pi-*@0.84.1` would enter this credentialed image with every digest check still passing. That is the same exposure the crewmate cell image already accepts for the same package; it is recorded here rather than described as a digest-pinned closure; the policy allows model egress only to Azure-provided DNS and the exact provider endpoint, denies instance metadata and the virtual network, and keeps tool/verifier repository execution networkless.
Plan legs are read-only; `image-build` and `policy-apply` are billable/security-sensitive, refuse without their exact confirmation flags and subscription, and run only from a clean checkout landed on public main.
Record the exact built image resource ID before any live review.
`image-build` distributes a managed image; the reviewer SKUs in [`azure-crosscheck/compartment.json`](azure-crosscheck/compartment.json) need the `DiskControllerTypes` feature a managed image cannot carry, so an operator promotes that managed image into a Compute Gallery image version and it is the gallery version's resource ID that `model_image_id` names.
That promotion is the one step of this contract the bounded command does not own, so a rebuilt image reaches reviews only after it is promoted and `model_image_id` is repointed.
Admission refuses a model image that does not attest the reviewer harness it is about to dispatch.
The build writes `pi-tarball-sha256`, `node-tarball-sha256`, `codex-cli-sha256`, and `claude-cli-sha256` onto the managed image it distributes, from the pinned closure; `require_model_image_attests_harness` in [`bin/fm-crosscheck-azure.py`](../bin/fm-crosscheck-azure.py) now reads them, so those previously unread tags are load-bearing.
Closing that read closes the gap PR #246 recorded: pointing `model_image_id` at an image built before a harness was added used to admit that harness and fail it inside a paid VM, one VM per attempt, on `pi: command not found`.
The check runs after the lane is held and after the foundation preflight, but before the capacity reservation, before any staged object, and before the model VM, so a refusal costs nothing.
It reads the configured image's own tags with one read-only ARM GET, and follows the version's source managed image exactly once when a required tag is absent there, because gallery promotion is a separate operator step that need not carry `artifactTags`.
A tag that is absent refuses, a tag that disagrees with the tracked closure digest refuses and names which digest disagreed, and an unreadable image, unreadable source, or unreadable tag object refuses rather than admitting: the guard never admits on ambiguity.
`pi` binds two tags, its tarball and its Node runtime, because Pi ships a `#!/usr/bin/env node` entrypoint and an image carrying `pi` without the pinned Node fails the reviewer at launch for the same reason and at the same cost.
Honest limit: this proves the configured image attests a harness, not that the harness runs. It reads what the build recorded about the image; a review completing on that image remains a separate claim, and a harness not in the attestation table (the retired `claude` lane) is refused rather than admitted.
The model guest launches Pi with `--offline`, so startup update checks and telemetry do not consume provider-only network waits before the review begins.

The pinned closure is tracked at [`azure-crosscheck/model-image-closure.json`](azure-crosscheck/model-image-closure.json).
It exists because the parameters file was previously operator-local and recorded nowhere: a built image's tags preserve each digest but not the URL or byte count the build also needs, so an image could not be reproduced from anything that outlived the shell that made it.
Compose the `--parameters` file by taking that closure and adding the installation-specific values, which are the only ones that legitimately vary:

```sh
guest=bin/fm-crosscheck-azure-model-guest.sh
python3 - <<'EOF' > /tmp/model-image.parameters.json
import base64, hashlib, json, pathlib
closure = json.load(open('docs/azure-crosscheck/model-image-closure.json'))
body = pathlib.Path('bin/fm-crosscheck-azure-model-guest.sh').read_bytes()
params = {k: v for k, v in closure.items() if not k.startswith('$')}
params['modelGuestSha256'] = {'value': hashlib.sha256(body).hexdigest()}
params['modelGuestBase64'] = {'value': base64.b64encode(body).decode()}
params['namingPrefix'] = {'value': '<prefix>'}
params['imageVersion'] = {'value': '<version>'}
params['builderIdentityId'] = {'value': '<image-builder identity resource id>'}
params['ubuntuExactVersion'] = {'value': '<exact marketplace version>'}
print(json.dumps({'$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#',
                  'contentVersion': '1.0.0.0', 'parameters': params}, indent=1))
EOF
```

The Pi entries must equal the crewmate cell image's, so a Pi reviewer and a Pi author run one identical agent rather than two versions that can disagree for reasons the review would report as a finding. `tests/fm-crosscheck-azure.test.sh` enforces that equality; it is not left to care:


Pi declares `engines.node >= 22.19.0` and ships a `#!/usr/bin/env node` entrypoint, so the Node pin is a correctness bound and not a preference: an older runtime or an unresolvable `node` on `PATH` fails the reviewer at launch rather than at admission.

### Pi reviewer account homes

Pi keeps every signed-in profile in one `auth.json` keyed by provider slot (`openai-codex`, `openai-codex-2`, ...), while every Firstmate consumer reads an account home holding exactly one credential under the fixed key `openai-codex`.
Pointing a reviewer at the pooled file therefore fails twice: only the first slot is ever read, so the selected profile is unreachable, and the reviewer credential archive would carry every signed-in account's tokens into a compartment that needs one.

`bin/fm-pi-account-home.py` writes the single-profile homes those consumers expect:

```sh
bin/fm-pi-account-home.py report
bin/fm-pi-account-home.py project --destination-root <root> --profile openai-codex-2
```

It validates credential shape, refuses a blanked or non-oauth profile, and reports expiry instants and account digests, never token material.
It does not decide whether a credential is still good enough to use: that question has one owner, `bin/fm-credential-expiry.py`, which the reviewer preflight runs.
Distinct profiles are distinct upstream accounts, so a Pi-versus-Pi review still satisfies account separation; `config/crosscheck-same-model` relaxes only the model screen.

The home-local configuration is optional and gitignored:

```json
{
  "enabled": true,
  "provider_host": "exact-provider-host.example",
  "provider_port": 443,
  "model_image_id": "/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/galleries/.../images/.../versions/1.0.0"
}
```

Omitting `reviewer_sku` spreads the default four lanes across the reviewed SKU families.
An explicit `reviewer_sku` remains an opt-in diagnostic override that pins every lane.

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
