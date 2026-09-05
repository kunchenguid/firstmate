# Trusted external process-event adapter bindings

This document is the maintainer-architecture owner for the package manifest, enabled binding, handshake, invocation envelope, trust boundary, and `process-event-adapter/1` capability.
[`configuration.md`](configuration.md#trusted-external-process-event-adapters-configextensionsd) owns operator setup and the home-local layout.
`bin/fm-extension.sh --help` and `bin/fm-procevent.sh --help` own command mechanics.

## Scope and design

The first extension binding is one complete vertical capability, not a general plugin system.
It lets a trusted package maintained outside Firstmate provide a long-polling process-event adapter while Firstmate core keeps source ownership, process supervision, durable capture, announcement, handling, and retirement.
The capability is explicitly enabled per home, independently installed per host, and permanently inert when the binding registry is absent.
It follows the project's vision by keeping consent explicit, commands flat and inspectable, mechanics deterministic, evidence non-authoritative, and the feature independent of every worker harness and session provider.

This version does not define lifecycle sinks, delivery providers, runtime backends, worker-launch grants, before or after hooks, instruction injection, project discovery, extension-selected destinations, task mutation, merges, decisions, force, discard, cleanup, or credential installation.
Adding another capability requires a separately reviewed contract rather than interpreting an unknown manifest field or operation optimistically.

## Trust boundary

A bound package is trusted same-user code, not sandboxed code.
The host validates identity and accidental or supply-chain change, but an executable running as the operator can use that operator's operating-system permissions outside the protocol.
Do not bind a package that is not trusted to that level.

Protocol responses are still untrusted evidence.
The host accepts only the fields and operations below, and no response can authorize a captain decision, merge, destination, stronger operation, force, discard, cleanup, or credential use.
External adapters do not receive the built-in `answers`, `autohandle`, or `self-announcing` seams.
A captured external result therefore remains unhandled until the existing Firstmate handling owner acknowledges it.

## Discovery and package installation

Discovery reads only regular mode-`0600` JSON files in the effective home's mode-`0700` `config/extensions.d/` directory.
The effective home follows the repository convention of `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked Firstmate root, but no environment value names a package or binding inside that home.
The current directory, project files, task copies, worker text, Pi packages, and package-manager metadata are never searched.
A package cannot bind an adapter name already owned by an installed `bin/fm-procevent-<adapter>.sh` built-in.
If a later Firstmate release adds the same built-in name, already captured extension evidence retains its immutable package owner and is never reinterpreted by that built-in; the pinned extension registration remains explicit until owner-matched retirement.

`bind` takes one explicit package directory outside the active home and outside every Git project or task copy.
It rejects path-component symlinks, symlinks anywhere in the package tree, hard-linked files, non-regular entries, files owned by another user, and group or world-writable package paths.
It bounds the tree to 4,096 entries and 64 MiB, includes every directory, relative path, executable bit, file size, and file digest in one deterministic SHA-256 tree digest, and separately binds the manifest and entrypoint digests.

After validation, the host copies the complete package into `data/extensions/packages/<id>/<version>/<tree-digest>/` under the active home.
Installed directories are mode `0555`, installed executable files are mode `0555`, and other installed files are mode `0444`.
Every invocation revalidates canonical confinement, owner, modes, links, the complete tree digest, manifest digest, and entrypoint digest before executing anything.
The enabled binding points only at that content-addressed home-local copy, so two local or remote homes install the same package identity at independent absolute paths.

## Package manifest

The package root contains one `firstmate-extension.json` document with exactly these fields:

```json
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.review-feed",
  "version": "1.2.3",
  "host_protocols": [1],
  "entrypoint": "bin/firstmate-extension",
  "capabilities": [
    {
      "name": "process-event-adapter",
      "versions": [1],
      "adapter_names": ["review-feed"]
    }
  ],
  "required_consents": ["network"]
}
```

The extension id is a lower-case dotted or dashed identity of at most 128 bytes.
The version is a semantic version string.
The entrypoint is one normalized relative POSIX path to a regular executable file inside the package tree.
Host protocols, capability versions, adapter names, and consent names are non-empty duplicate-free arrays, except that `required_consents` may be empty.
This manifest version accepts exactly one `process-event-adapter` capability and rejects every unknown top-level or capability field.
Supported consent facts are `network`, `credential-store`, `task-metadata`, and `artifact-references`.
The host records every fact as true or false and requires an explicit `--consent` for each fact the manifest requires.
`credential-store` is the only fact that changes the minimal child environment: when true, the host may preserve the operator's home and standard credential-store path variables.
The other facts are honest consent records rather than an operating-system network or filesystem sandbox.

## Enabled binding

`bind` generates the binding, so operators never hand-author hashes or duplicate machine-generated package state.
The mode-`0600` document has schema `firstmate.extension-binding.v1` and exactly these fields:

- `extension_id` and `extension_version` match the manifest.
- `source` records the canonical local-directory source path for inspection or reinstall.
- `package_root` is the canonical content-addressed path in this home.
- `manifest_sha256`, `package_digest`, `entrypoint`, and `entrypoint_sha256` bind the complete installed identity.
- `host_protocol` is the highest common supported host protocol.
- `capabilities` contains only the explicitly enabled adapter-name subset and selected `process-event-adapter` version.
- `consents` records `trusted_same_user_code` plus every supported consent fact as an explicit boolean.
- `timeout_ms` bounds one invocation between 100 and 3,600,000 milliseconds.

The host supports at most 128 binding records and refuses malformed, unsafe, duplicate-id, or duplicate-adapter registries rather than selecting around them.
Binding publication is atomic and does not replace a concurrent file.
`list`, `inspect`, and `verify` expose the resulting identity and live compatibility without creating state when no registry exists.
Binding publication prints the binding digest used as its conditional retirement identity.
`retire-binding` fully validates the current binding and installed package, refuses a stale digest or a transferred source, and atomically moves only that exact local binding into `data/extensions/retired-bindings`.
One home-local lifecycle lock serializes extension resolution through registration publication against dependency preflight through exact binding removal, and the retirement worker owns that lock with its own process identity for the full mutation lifetime.
Before either retirement form, the process-event owner refuses while an exact registration or unhandled captured result still depends on the binding.
Retirement disables discovery and invocation without deleting the content-addressed installed package, and retained binding state can be restored deliberately.

## Executable protocol

The host invokes one exact package entrypoint directly with `shell=false`, the package root as its fixed working directory, a minimal environment, and one verb argument.
It never uses `source`, `eval`, a shell command string, or package-supplied argv.
The entrypoint reads exactly one UTF-8 JSON document from stdin and writes exactly one UTF-8 JSON document to stdout.
Logs must use stderr.

Each JSON envelope is limited to 65,536 bytes, extension stderr is limited to 8,192 bytes, and a raw process-event result is limited to 32,768 bytes so it can be carried into later classification requests.
The parser rejects malformed UTF-8, a byte-order mark, duplicate object keys, unknown fields, unescaped controls, unpaired surrogates, multiple documents, and trailing bytes.
A tracked static core launch barrier publishes one exact host-created process group before the host releases package code, without `eval`, generated source, a shell, or a package-controlled bootstrap.
A timeout, output-bound violation, failed response, host interruption, or successful parent that leaves that group live sends `TERM`, escalates to `KILL`, and rejects the invocation until that exact group is proved gone.
If the host dies first, its private identity-bound cleanup record keeps source reconciliation, home cleanup, and binding retirement from releasing ownership until a later core invocation proves that exact group extinct; an uncertain or reused live identity is retained and never signalled.
Extension children must remain foreground members of their invocation group and be owned and reaped by the live entrypoint. Starting another session or process group, changing process groups, double-forking, reparenting, or surviving the entrypoint response violates this protocol contract.
Trusted same-user code is not an operating-system sandbox: deliberate process-group escape is outside this protocol guarantee. The host never infers ownership from process-table scans or signals contemporaneous same-user processes outside the exact invocation group.
Extension stderr and failure diagnostics are never copied into a wake or authority-bearing record.

### Handshake

Before enablement, registration resolution, and every invocation, the host runs the entrypoint with verb `handshake`.
The request has exactly these fields:

```json
{
  "schema": "firstmate.extension-handshake-request.v1",
  "request_id": "sha256:<64 lowercase hex>",
  "host_protocols": [1],
  "extension_id": "org.example.review-feed",
  "extension_version": "1.2.3",
  "package_digest": "sha256:<64 lowercase hex>",
  "capability": {
    "name": "process-event-adapter",
    "versions": [1],
    "adapter_names": ["review-feed"]
  }
}
```

The response has exactly `schema`, `request_id`, `extension_id`, `extension_version`, `host_protocol`, `capability`, `capability_version`, and `adapter_names`.
Its schema is `firstmate.extension-handshake-response.v1`.
Every identity must match the request and enabled binding exactly, including the request id and enabled adapter-name subset.
There is no wildcard, optimistic fallback, or silent downgrade.

### Invocation envelope

After a successful handshake, the host runs the same entrypoint with verb `invoke` and sends exactly these fields:

```json
{
  "schema": "firstmate.extension-request.v1",
  "request_id": "sha256:<64 lowercase hex>",
  "host_protocol": 1,
  "extension_id": "org.example.review-feed",
  "extension_version": "1.2.3",
  "package_digest": "sha256:<64 lowercase hex>",
  "capability": "process-event-adapter",
  "capability_version": 1,
  "adapter": "review-feed",
  "operation": "source.poll",
  "input": {
    "source_id": "review-feed-main",
    "config_ref": "main"
  }
}
```

The response has exactly `schema`, `request_id`, `ok`, `result`, and `error`.
Its schema is `firstmate.extension-response.v1`, and its request id must match exactly.
A successful response has `ok=true`, one operation-specific result object, and `error=null`.
A failed response has `ok=false`, `result=null`, and an error with exactly `code`, `retryable`, and a bounded `diagnostic`.
Allowed error codes are `invalid-request`, `incompatible`, `conflict`, `unavailable`, and `internal`.
The host does not relay the package's diagnostic text into process-event evidence.

## `process-event-adapter/1`

The capability has four operations:

| Operation | Input | Successful result | Core action |
| --- | --- | --- | --- |
| `source.poll` | `source_id`, bounded `config_ref` | `{status:"result", output:"..."}` or `{status:"no-result", output:""}` | The generic runner captures non-empty output as external evidence before publishing the existing `check` event. |
| `result.classify` | `source_id`, `sequence`, `content` | `{classification:"lower-case-token"}` | Prints evidence for the handling agent and changes no state. |
| `result.terminal` | `source_id`, `sequence`, `content` | `{value:true|false}` | Core conditionally retires only the exact registration generation it owns. |
| `result.silent` | `source_id`, `sequence`, `content` | `{value:true|false}` | Core records handling only for a positive, valid verdict; every failure publishes the result. |

A long-poll implementation must return `no-result` before its bound timeout when no event arrives; a host timeout is an actionable package failure, not a normal discovery cadence.
The shipped example uses a 55-second finite wait inside the default five-minute host bound, so an absent file produces no result and no wake before ordinary reconciliation starts the next wait.
The package never receives a result-file path.
A source configuration reference is a bounded non-secret identifier or path reference stored in the private registration and sent in JSON; credential values must stay out of the reference, argv, envelopes, diagnostics, and process-event records.
Before an external invocation can open its runner-output staging file, core validates the effective state directory and its `state/procevent/` registry as canonical, same-user, non-link private directories with safe modes.
Before an external result can be captured, core applies the same boundary checks to the effective state directory and its `state/procevent-inbox/` destination.
These external-only checks refuse before a staging or capture write when a post-registration link, ownership, mode, or canonical-path substitution is detected, while the legacy four-argument built-in capture path retains its existing behavior.
For `result.terminal` and `result.silent`, the live core runner passes the host an internal one-shot handoff that pins the exact active claim, inbox, and result identities before the host reads a regular mode-`0600` result and sends only bounded UTF-8 content.
Public lifecycle entry, environment, paths, and caller-supplied descriptors cannot create that handoff or authorize capture; runner claim release and dead-owner reconciliation remove its pending or consumed reservation state from the claim's recorded, revalidated state root.
A source failure becomes a small host-produced `firstmate.process-event-extension-error.v1` result, so missing packages, invalid responses, crashes, nonzero exits, and timeouts become actionable evidence rather than silent fallback.
Unknown or malformed terminal and silent responses take the safe false path.

External registration stores the extension id and version, capability version, package digest, binding digest, source configuration reference, and a fresh random registration token beside the adapter and source id.
For `source.poll`, core derives the request id from that registration generation and the next uncaptured source sequence, so a retry before durable capture reuses the same id while the first invocation after a capture receives the next id.
Captured results retain the immutable extension identity needed to classify them later.
`register-extension` prints the exact token-bound retirement command.
`retire --if-owner <token>` removes only that registration generation, so an older owner cannot retire a replacement even when the extension, adapter, and source id are otherwise identical.
Legacy built-in records remain readable and keep unconditional retirement, while `--if-matches` adds an exact complete-record condition for built-in callers and `--if-absent` supports absence-conditioned cleanup.

## Compatibility and failure semantics

An absent `config/extensions.d` directory remains permanently inert and creates no package, state, or registry path.
Built-in filename adapters remain authoritative and unchanged during this migration window.
Host protocol 1 and `process-event-adapter/1` remain accepted throughout the first release that introduces a successor, and cannot be removed before the following release.
An unknown enabled version refuses rather than downgrading.

A missing or changed package never executes.
A malformed binding, integrity mismatch, failed handshake, crash, nonzero exit, timeout, oversized stream, wrong request id, or invalid response never selects another adapter.
A source invocation failure is captured as bounded host evidence and remains unhandled.
A classification, terminal, or silence failure returns no positive verdict.
Replay uses the exact request id as the package's idempotence key, including a stable pre-capture retry from the generic runner, but Firstmate makes no generic exactly-once or source-side losslessness claim.
The process-event durability boundary remains owned by [`configuration.md`](configuration.md#process-to-event-sources-stateprocevent).

## Runtime independence

The host runs in the Firstmate home that owns the source, never in a task worker or its session container.
Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, and Muse therefore expose no package-loading surface for this capability.
The result reaches every supported primary through the existing bounded `check` wake path, including the unknown-protocol fallback used where no specialized primary continuation exists.
The tmux, Herdr, Zellij, Orca, cmux, and thurbox session providers are not consulted because a process-event source has no task endpoint.
Remote and local secondmate homes bind and install independently, and the primary never executes a missing remote-home package locally. `remote-bind` carries one canonical `firstmate.extension-package-transfer.v1` JSON envelope over the existing bounded `fm-on` stdin/stdout job. Its hashed manifest pins the extension id, version, complete package-tree digest, entry count, total bytes, and byte-sorted entries. Entries are limited to normalized relative directories at mode 0755 and single regular files at mode 0644 or 0755, each with an exact size and SHA-256 payload digest. The receiver accepts at most 128 entries, 256 KiB per file, 512 KiB of package bytes, and 900,000 serialized bytes; it rejects malformed or truncated JSON, duplicate keys or paths, collisions, absolute or traversing names, links and special files, noncanonical modes, hash or size mismatches, and duplicate transfer identities.

The receiver creates the package in a private temporary directory below `data/extensions/staging`, validates ownership, permissions, the package manifest, executable, and complete reconstructed tree, then atomically publishes the transfer before the normal bind handshake and binding publication.
A failed bind moves the exact transfer identity into `data/extensions/retired-staging` without enabling it.
`retire-transfer` requires both transfer and binding digests, then revalidates the receipt, version directory, staged manifest identity, staged complete-tree digest, installed package, enabled binding, and binding source path as one identity.
It refuses missing, ambiguous, drifted, mismatched, in-use, or unrelated state before moving the enabled binding into the staged identity and reversibly moving that exact unit into `data/extensions/retired-staging`.
If the process stops between those two moves, a retry resumes only when the retained binding and staged receipt, version directory, package, transfer digest, and binding digest still form that one exact retirement identity; altered or coexisting partial state is refused.
The transfer contains package bytes and declarative metadata only: it carries no environment, credentials, cookies, tokens, destinations, or caller-selected command text and creates no generic file-transfer surface.
Bindings and credentials are deliberately absent from the inherited secondmate configuration allowlist.

## Runnable example

[`examples/process-event-extension`](examples/process-event-extension) is a complete external `file-signal` adapter package.
It waits for one configured absolute file, returns that file's bounded UTF-8 contents as evidence, classifies the result as `file-signal`, and reports it terminal.
The package is intentionally copied outside this Git project before binding, proving that project-local package discovery is not a registration path.
The operator commands live in [`configuration.md`](configuration.md#trusted-external-process-event-adapters-configextensionsd), and `tests/fm-extension-binding.test.sh` runs the complete example path.
