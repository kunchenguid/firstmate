# Azure Crosscheck runtime

The operator contract and agnostic invocation are in [crosscheck.md](crosscheck.md).
This document owns only the Azure implementation boundary.

## Topology

Crosscheck keeps one reusable reviewer VM in the reviewed policy subnet. The VM
uses the pinned reviewer image, Trusted Launch, encrypted host storage, no public
IP, no managed identity, and a blackhole SSH public key whose private half is
not held by an operator.

The controller admits up to four local FIFO lanes. Every lane submits a uniquely
named Azure Managed Run Command to the shared host. A run gets:

- one random dispatch nonce;
- one derived 24-character review generation;
- unique staging blob names;
- one private `/var/lib/fm-crosscheck-model/<generation>` directory;
- one credential archive and one exact-head read-only repository snapshot.

The guest validates all bound identities, runs Pi or Codex with only its bounded
review interface, uploads the structured result, and removes the generation
directory on exit. The controller then deletes the run-command child and the
generation's staged blobs. The VM, NIC, and OS disk remain for later reviews.

## First creation

`docs/azure-crosscheck/compartment.json` is also used by historical disposable
workflows. Its `persistent` parameter defaults to `false`, preserving their
safety-shutdown timer. Crosscheck passes `persistent: true` for the shared host,
so that timer resource is not created.

The shared names are stable:

```text
vm-<prefix>-cc-reviewer
nic-<prefix>-cc-reviewer
disk-<prefix>-cc-reviewer-os
fm-crosscheck-reviewer-host
```

Before every dispatch the controller reads the host. It reuses a running host,
starts a stopped host, and refuses an existing host whose workload tags, image,
or SKU do not match current configuration. If the host is absent, one local
provision lock ensures concurrent first callers create it once.

Image attestation tags remain load-bearing. Admission refuses a model image
that does not attest the reviewer harness. That attests a harness, not that the
harness runs; the exact run/result identity supplies the latter binding.

## Concurrency and isolation

`FM_AZURE_CROSSCHECK_LANES` defaults to four and can be set from one through
eight. Lane locks are held for the full review and released automatically if a
local process exits. Queue tickets are FIFO and stale tickets from dead local
processes are removed.

Managed run-command resource names include the full review generation. Guest
directories use the same validated hex generation and refuse reuse. A retry
gets a fresh nonce and therefore cannot collide with the earlier command,
directory, or blobs even when task, PR head, and ledger are unchanged.

Credentials exist only inside their generation directory and the short-lived
staging blob. Concurrent reviews do not share account homes, private homes,
snapshot trees, result files, or temporary directories.

## Durable identity

Each accepted run binds the exact head, merge base, claims digest, reviewer
account digest, provider/model, model image, SKU, deployment generation,
request digest, result digest, VM resource ID, immutable VM instance ID, boot
ID, and generation cleanup state.

The shared-host identity sets `host_mode: shared-v1`. It carries no tool or
verifier VM identity and its evidence-attempt arrays are empty. Validation keeps
the old disposable record shape readable for historical ledgers.

## Failure behavior

Infrastructure failures never become review findings and never clear a PR.
Provider or structured-verdict failures use the existing bounded reviewer
repair/fallback policy. Host, staging, result, or cleanup failures are reported
as tool failures. A completed semantic result is persisted before any later
generation-cleanup alarm so a cleanup problem cannot erase the paid review.

No run deletes the shared VM. Replacing a mismatched host is an explicit runtime
rollout action rather than an incidental side effect of a PR review.
