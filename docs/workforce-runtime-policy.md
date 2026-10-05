# Workforce execution policy

The typed bridge exposes contract revision 1.5 without changing request wire v1.
The authoritative frozen policy and allocation wire is the header and executable validation in [`fm_workforce_policy.py`](../bin/fm_workforce_policy.py).
The supervisor command surface is [`fm-workforce-policy.py`](../bin/fm-workforce-policy.py), and the bridge command surface remains [`fm-workforce.py`](../bin/fm-workforce.py).

A reviewed job may attach an execution policy with revision digests for the global, optional company, project and job snapshots.
These are immutable provenance supplied by the requester, not grants or proof that an external company policy was deployed.
Admission binds the entire frozen scope and payload to one allocation identity.
Every note admitted under that identity must match the frozen request and consume a distinct slot.
The admission owner serializes slot reservation together with its existing request-to-task reservation.
A requested finite root quantity defines a workload allocation; it does not impose a global fleet concurrency ceiling.
The supervisor captures additional roots with `allocation-request`, writes each task's ordinary brief and backlog item, resolves dispatch, and invokes the existing spawn owner with its origin note.
The capture operation uses deterministic request identities and identical replay; it never dispatches workers or approves their execution.
Disposable task workers remain the allocation unit.
Persistent secondmate homes are outside this operation and retain their existing optional provisioning owner.

Prepared reservations remain occupied if dispatch fails or restart leaves incomplete evidence.
They are never silently recycled or interpreted as permission to repeat a spawn.
Committed admissions retain the inbox owner's immutable original generation while relaunch replaces the current runtime generation and preserves the allocation slot.
The existing admission recovery operation repairs publication without launching another worker.
Historical root slots remain reserved for that frozen workload even after retirement; a new workload requires a new allocation identity.

## Effective observations

Bridge status adds `execution_capabilities` and `effective_policies`; receipts expose the frozen `allocation` separately from admission and, when current custody is proven, an `effective_policy` observation.
A requested snapshot, a prepared allocation, a committed admission and a running process are different observations.
The capability schema is `fm-workforce-policy-capabilities.v1`, the reservation schema is `fm-workforce-allocation.v1`, and effective observations use `fm-workforce-effective-policy.v1`.

Host runtime records are immutable per generation under the task's private runtime directory.
The native wrapper refuses a second launch for an already recorded generation.
On Linux it checks process start time and the exact native-control argument sequence before reporting occupied, running execution.
Missing evidence, changed generations, unsupported process inspection, malformed records and identity mismatches remain unknown.
This is trusted local owner evidence, not a security attestation against a user who can alter the host, executable or records.
It does not create a credential store or change the existing authorized host Assistant route.

## Supported limits and routes

| Surface | Current guarantee |
|---|---|
| Root crew | Immutable workload slots reserved by the existing serialized admission owner; no independent scheduler. |
| Codex native descendants | Exact installed 0.159.3 version and native configuration readback, followed by controls injected into the actual launch; concurrent native session descendants exclude the root. |
| Zero Codex descendants | Both native multi-agent feature switches and agent enablement disabled; V2 is explicitly disabled because it takes precedence. |
| Depth, total descendants, tokens, cost | Hard requests refused; no prompt or iteration setting is represented as a quota. |
| Other native adapters | Hard counts unavailable through this owner until an adapter establishes and tests its current native contract. |
| Host filesystem, network and credentials | Existing host-worker authority; native thread limits do not constrain arbitrary shell processes or external services. |
| OpenShell | Existing Herdr Codex owner, exact workspace identity, generation-bound journal, policy digest and workload-side native readback before agent start. |
| OpenShell filesystem and providers | The [OpenShell owner](openshell-codex.md) retains its boundary and recovery contract; observations distinguish the submitted hard-requirement filesystem policy from provider-dependent effective network and credential restrictions. |
| Company VM | Refused without an authorized execution owner; no host fallback, live provisioning or inferred company grant. |

OpenShell continues to require a registered gateway, reachable compute, reviewed workload image and already authorized providers.
Its existing delivery capability supports no-mistakes ships, so an OpenShell Direct-PR request refuses rather than receiving host forge credentials or falling back to host execution.
A policy-bound workload must pass the native probe inside that exact sandbox; a host CLI cannot supply this evidence.
Sandbox-running evidence does not prove an agent is still active, or attest that provider rules enforce an arbitrary requested endpoint restriction.
No browser request can supply privileged paths, shell commands, credentials, network rules or a gateway policy deployment.

The [native guard](../tests/fm-workforce-policy-native.test.sh) refreshes installed configuration and actual credential-free process evidence.
The [admission regression](../tests/fm-workforce-admission.test.sh) exercises allocation bounds, frozen conflicts, idempotent capture and admission custody.
The [OpenShell regression](../tests/fm-openshell-codex.test.sh) exercises workload routing, journal identity, transfer and recovery using disposable executable fixtures.
Live authenticated inference, provider enforcement and sandbox escape acceptance require their actual installed prerequisites and are not implied by those fixtures.
