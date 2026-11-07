# OMP worker in a Kepler Terminal

This is an explicit manual worker surface supervised by Firstmate.
It prepares a supported Kepler `agent.customServers` entry with `kind: terminal` and runs one approved programmatic OMP SDK prompt after owner activation gates pass.
It does not change the configured Firstmate runtime backend or worker defaults.
The trusted host limits this implementation to the named ATX-2170 command-center pilot task and one canonical command-center worktree.

The controller's [header and template command](../bin/omp-kepler/controller.py) own host and capsule formats and command mechanics.
The [worker contract](../bin/omp-kepler/contract.ts) owns authenticated credit and mutation-receipt formats.
The [entrypoint](../bin/fm-omp-kepler.sh) owns the manual commands and fixed registration record.
The [owner record producer](../bin/omp-kepler/record_signer.py) owns the prepared capsule, mutation, and credit signing commands.

## Current availability

Implementation-only authority refuses before operational SDK imports.
ATX1758 OWNER ACTION PENDING remains a separate activation decision.
Installation, login materialization, provider use, merge, and production are separate gates; this controller supports an approved provider-only worker and never grants the other actions.
Kepler task and worktree identities are supplied by the signed capsule or recorded as unknown; an FM task identifier does not verify a Kepler session.
This surface is not a drop-in replacement for `fm-spawn.sh`'s interactive OMP launch.
It does not enroll a fleet member or write Firstmate's semantic busy records.

## Owner preparation

After separate owner approval, provision the root-owned, non-writable `/etc/firstmate/omp-kepler/host.json` and its root-owned Ed25519 public verification key.
The owner signing key belongs to an authenticated FM control broker outside the worker's filesystem and account access.
An editable key, a same-user queue token, or a caller boolean cannot establish captain approval.
Use the entrypoint's template output to prepare the host record and an immutable signed capsule for the assigned canonical worktree and exact Git head.
Bind all producer source hashes and the complete private runtime tree digest to both records.
Signature and digest serialization uses sorted UTF-16 object keys, valid Unicode strings, and exact binary64 decimal numbers without exponent notation.
Negative zero serializes as zero; nonfinite numbers, unpaired surrogates, and numbers outside plus or minus 9,007,199,254,740,991 refuse.
This serialization is shared by the Python producer and TypeScript verifier and preserves finite fractional model costs and receipt timestamps.
The SDK runtime is private Bun 1.4.0 plus the complete SDK 18.1.11 dependency tree; a monolithic OMP CLI executable does not provide this SDK.
The controller's `tree_digest` function owns dependency-tree serialization.
The host requires Linux, `/usr/bin/python3`, `/usr/bin/openssl` with Ed25519 `pkeyutl`, `/usr/bin/git`, and a working Unix socket directory.
Keep the signing key and owner control records outside worker-visible paths and preserve one trusted writer for the worktree.
Every host-record path that controls a read, write, import, execution, or owner-key check must be absolute and already canonical; relative paths and symlink-normalized aliases are refused before effects.
The signed capsule's worktree and credential file must also be absolute and canonical.
Exact-head validation uses fixed `/usr/bin/git` with a bounded environment, not ambient `PATH` or user Git configuration.
The adapter source directory, pinned Bun binary, pinned `node_modules`, state root, capsule root, and credential file must not overlap the assigned model-editable worktree.
The observed Hermes Kepler server runs as root, so the prepared registration invokes a fixed `/usr/sbin/runuser -u fm-omp-worker -- ... launch <task>` handoff after validating the capsule and worktree.
The host record binds that literal unprivileged account's verified UID and primary GID; a missing or mismatched account refuses before SDK imports.
Provision that account, its private credential/state directories, worktree access, and the fixed runuser dependency only after the separate installation decision.
The owner console and root-only signing key remain under distinct root custody; the worker account receives no sudo access, signing-key access, or owner-console authority.
A root-launched worker could read a root-owned key, so direct root worker execution is refused.
No account, ownership, sudo, or host configuration is changed by this preparation.
Place the fresh bootstrap beneath a canonical neutral state root outside every enclosing VCS repository and ambient configuration or instruction directory.
Before operational imports, the controller's authority validator refuses enclosing Git/Hg/SVN/JJ markers, native agent configuration directories, settings files, environment files, and WATCHDOG/AGENTS/CLAUDE instructions.
It also refuses startup sources in the explicit bootstrap agent/config directories; post-start private auth/model database files do not grant discovery authority.
The guard prevents SDK startup scans and `@import` expansion from inheriting another repository's instructions.

The supported credential file contains one opaque access credential for the exact approved provider and account, without surrounding JSON.
It is private to the launch account, outside the worktree, and passed through an inherited file descriptor.
An existing ChatGPT or Claude `auth.json` is not that format and must not be copied into it.
The adapter performs no login, OAuth refresh, account selection, or credential discovery.
Any required credential materialization must follow separately approved provider-specific login handling.

The FM broker must publish signed provider account and usage evidence to the task's `credit.json` before launch and refresh it while the worker runs.
Every guarded provider request requires a matching authenticated receipt observed within 60 seconds, a current validity bound, included credit, and zero overage.
The adapter authenticates and binds the broker's evidence; provider-plan truth and the sufficiency of those evidence references must be established by the owning broker before activation.
Missing, stale, expired, mismatched, or unreadable evidence stops the request.

Prepare the registration record, review it, and apply it to Kepler only after installation is authorized.
Select the resulting `custom:<id>` agent in the assigned task and manually launch its Terminal from that task's canonical worktree.
Commands and arguments are fixed absolute values without placeholders.
The Terminal submits the capsule's approved brief once; terminal input cannot submit another prompt, select a model, or change settings.

## Mutation approvals

Crew exposes only the confined `read`, `grep`, `write`, and `edit` tools; scout exposes only `read` and `grep`.
Mutation approval previews carry the task, immutable capsule hash, fresh nonce, exact arguments digest, canonical target path, target fingerprint, before and after content hashes, and expiry.
The approval-only UI publishes `<nonce>.request.json` beneath the task's `approvals` directory.
The authenticated external FM broker responds with `<nonce>.receipt.json`, an Ed25519 envelope over the unchanged request fields plus `decision: approve` or `decision: deny`.
The worker verifies the fixed owner public key, exact binding, expiry, and single use before allowing the native approval gate and rechecks the target before writing.
Invalid or missing responses deny the mutation.
Writes stage and verify the complete content before rechecking the approved target fingerprint and replacing it; short, zero-progress, or failed staged writes preserve the target.
The prepared owner-only producer can sign and publish a reviewed capsule, approve or deny an exact pending mutation, and publish externally verified credit evidence.
Its fixed root-only owner key must be enrolled through the authenticated owner control channel; neither the worker account nor an arbitrary sudo caller is treated as captain identity.
The producer never queries a provider or creates a signing key.
This implementation run does not install that owner console, key, or approval channel.

Paths must be relative and anchored to the assigned worktree.
Traversal, absolute paths, symlinks, hard links, non-regular files, credential/config/control names, and oversized files are refused.
Grep is a literal search bounded by file count and output size.
The wrappers do not expose shell, Python, JavaScript, network, MCP, LSP, IRC, extensions, or subagent tools to the model.
This is a confined tool interface under trusted host and single-writer custody, not a proof against a hostile process replacing trusted ancestors or runtime files concurrently.

## Lifecycle and verification

The independent watchdog owns the worker process group, monitors controller loss and the deadline, terminates then kills when necessary, and reaps the worker.
Linux identity binds the boot ID, owned PID start ticks, parent, and process group.
Mac inert tests use a weaker portable process identity and cannot activate the operational branch.
Durable adapter receipts include task, capsule and source bindings, busy state, sequence, terminal receipt, exit, and reap classification.
An authenticated worker result with a successful assistant stop is retained separately as a bounded private `result.json`.
Public status excludes the interrupt capability.
Reconnect reads the receipt without submitting a prompt; interrupt reports request acceptance and separately verifies the owned worker stopped.
A quiet Terminal or successful process exit without a terminal agent receipt is failure.
Malformed worker receipts and exceptional watchdog cleanup retain a failed, exited, and reaped classification when the owned receipt is still available.
Unexpected-stop recovery is pinned to `none`, alongside disabled retry and advisor behavior.
Process-group confinement does not cover a hostile descendant creating a new session, and the adapter is not a general OS sandbox.

Run the [portable behavior suite](../tests/fm-omp-kepler.test.sh) with a pinned private Bun to exercise real inert children, the filesystem boundary, cryptographic fixture receipts, and an injected fake SDK.
Strict compilation uses the pinned SDK's public types without constructing an SDK session.
These checks establish the prepared contract and inert lifecycle behavior; live SDK/provider, Kepler Terminal, authenticated broker, and native Firstmate acceptance remain separate activation proof.
