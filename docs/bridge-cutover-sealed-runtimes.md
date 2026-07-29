# Bridge sealed runtime and cutover control plane

## Scope

The control plane lives under `tools/bridge-cutover` and does not discover or mutate live account credentials.

The builder produces exactly four immutable roles from a strict schema-v2 manifest.

- Agent Fleet candidate is version 0.2.0 with contract version 2.
- Agent Fleet rollback is version 0.1.5 with contract version 1.
- Quota AXI candidate is version 0.1.7 with exact-account Keychain lookup.
- Quota AXI rollback is version 0.1.5.

The manifest supplies exact source repositories, full Git commits, source-tree digests, package artifacts, dependency closure, Python and Node runtimes, build tools, output paths, and the installed Agent Fleet front-door path.

The builder reads no live release, account registry, credential directory, browser state, desktop session, or ambient package cache.

No sealed adoption, normal cutover, live-checkout change, Desktop-app or provider-auth change, routing activation, or live canary may run until the Bridge cutover code is merged to `main`, the labs pass from that merged code, and the captain explicitly declares the quiet point.

## Build contract

Run the builder with an absent proof path and four absent release paths.

```sh
python3.11 tools/bridge-cutover/build_sealed_bridge_runtimes.py \
  --manifest /absolute/private/path/sealed-runtime-input.json
```

The input manifest has this shape, and every omitted or additional field is refused.

```json
{
  "schema_version": 2,
  "output_root": "/absolute/sealed-output",
  "proof_manifest": "/absolute/sealed-output/proof-v2.json",
  "operator_front_door": "/absolute/user-bin/agent-fleet",
  "transaction_driver": {"path": "/absolute/bridge_cutover_transaction.py", "sha256": "<sha256>"},
  "tools": {
    "clang": {"path": "/usr/bin/clang", "sha256": "<sha256>"},
    "codesign": {"path": "/usr/bin/codesign", "sha256": "<sha256>"},
    "file": {"path": "/usr/bin/file", "sha256": "<sha256>"},
    "git": {"path": "/usr/bin/git", "sha256": "<sha256>"},
    "otool": {"path": "/usr/bin/otool", "sha256": "<sha256>"},
    "xattr": {"path": "/usr/bin/xattr", "sha256": "<sha256>"}
  },
  "python_runtime": {"root": "/absolute/python", "version": "3.11.x", "binary_sha256": "<sha256>", "tree_sha256": "<sha256>"},
  "node_runtime": {"binary": "/absolute/node", "version": "20.x", "sha256": "<sha256>"},
  "agent_fleet": {"candidate": "<exact role object>", "rollback": "<exact role object>"},
  "quota_axi": {"candidate": "<exact role object>", "rollback": "<exact role object>"}
}
```

User-owned inputs and output directories require current-user ownership, non-writable ancestry, canonical paths, and single-link regular files where applicable.

Pinned macOS system tools may be root-owned only under root-owned, non-writable system ancestry.

The transaction driver remains a current-user-owned mutable control-plane input and cannot use the system-tool exception.

## Offline Quota build proof

Generated Quota AXI `dist/**` bytes are accepted only through a separate producer/consumer contract.
The producer is `tools/bridge-cutover/build_quota_axi_offline_proof.py`; the sealed-runtime builder independently consumes and revalidates its strict schema-v1 proof.

The producer requires an exact Git commit and canonical archive-tree digest, root-owned `/usr/bin/git`, Node 20, an exact npm closure and empirical npm version, a pinned initial offline cache, an exact build `package-lock.json`, an exact build-only `package.json`, every retained `file:` artifact, and the exact compiler path, digest, and arguments.
A build-lock record must have an exact version, npm SHA-512 SRI, and either a retained hash-pinned `file:` artifact or an npm-registry URL satisfiable from the pinned offline cache.
No ambient cache or network fallback is permitted.

The build-only `package.json` may reduce the source development closure to the exact compiler and runtime dependencies.
Its complete JSON difference from the source commit is recorded.
The exact source `package.json` is restored before packing, and npm's subsequent packing normalization is recorded separately.

The producer archives and builds the exact source commit twice in deterministic, attributed workspaces.
Both source archives, package member maps, and complete tarball digests must match.
The proof inventories every package member, every generated member (which must be under `dist/`), the build-lock graph and SRI records, both package-normalization maps, the full toolchain, and the final tarball digest.

The consumer reopens and hash-verifies the producer helper, Git, Node, npm tree, cache tree, build package, build lock, retained file artifacts, and proof itself.
It recomputes the source binding, lock graph, normalization maps, generated `dist/` closure, member inventory, and tarball binding.
A proof that merely asserts success without those retained bytes is refused.

## Runtime closure

Agent Fleet wheels must match their exact source commits and may contain only the permitted package and generated distribution metadata closure.

Each Agent Fleet role explicitly binds `source_subdirectory` to `.` for a standalone source repository or to the normalized embedded package root such as `tools/agent-fleet`; the wheel must match that exact committed subtree.

The pinned Python 3.11 runtime may contain relative symlinks only when they resolve to regular files inside that same runtime.
The source-tree digest binds the lexical link target and resolved file digest.
Sealed releases materialize each accepted link as a regular file and record the complete transformation list; absolute, dangling, non-file, and escaping links are refused.

The candidate wheel and proof set require the enrollment, identity, provision, and recovery modules that implement the sealed activation contract.

Preparation invokes those planning APIs itself under a guard that refuses process and shell execution, so a candidate whose planning path shells out to any external tool is refused instead of prepared.
It also binds the candidate registry to the specification's `live_registry` path, because the sealed provision API composes managed hook commands from the loaded registry path and the recorded plans must match what post-cutover provisioning produces against the exact path runtime hooks embed.
`tests/test_prepare_bridge_cutover.py` pins both: a gate that drives the real Agent Fleet package through prepare's own loader under that guard, and a synthetic provision API that refuses a registry carrying no path.

Quota AXI package members and dependency tarballs must match their exact source commits and lock file without ambient npm resolution.

Quota AXI 0.1.6 is disqualified and refused by both the builder and preparer because its Claude Keychain reads did not bind the passwd-derived account.

The 0.1.7 candidate binds both presence and value reads to service plus passwd-derived account, closes stdin, uses the physical system security tool, and has no service-only fallback.

The final 0.1.7 source commit, source-tree digest, package digest, lock digest, dependency digests, and release path remain mandatory external sealed-manifest inputs.

The Agent Fleet launcher verifies its complete protected Python closure before executing the six-line isolated bootstrap.

The Quota AXI launcher verifies its complete Node and package closure before directly executing the sealed entrypoint.

Both launchers derive authority from the canonical physical executable path reported by macOS and never trust `argv[0]`.

Both launchers require their physical executable to be a current-user-owned, mode-0555, single-link regular file.

Ordinary PATH invocation and hostile `argv[0]` invocation reach the same physical launcher authority.

Symlink aliases, hardlinks, content drift, mode drift, owner drift, unexpected files, and hostile environment injection are refused.

The generated `operator/agent-fleet` payload is a native hardened-runtime front door bound to one exact sealed Agent Fleet launcher path and digest.

The installed front door is always a regular mode-0555 single-link file after adoption and is never a symlink during sealed operation.

## Determinism, durability, and recovery

Each invocation builds all four roles twice with one publication identifier and requires identical transaction-driver tree digests.

The proof retains the byte-for-byte schema-v2 builder manifest and canonical digest, builder, bootstrap, transaction driver, all system tools, Python source tree and link transformations, Node runtime, source repositories and commits, wheels, Quota packages, locks, build proofs, dependency tarballs, and dependency SRI values.
Preparation reopens these retained inputs instead of trusting labels copied into a release.

Both rebuilt Agent Fleet releases execute their copied Python with a closed environment and must report the pinned `Python 3.11.x` version.
Both rebuilt Quota releases execute their copied Node with the same closed environment and must report the pinned `v20.x` version.
The exact four observations are retained in `runtime_versions` and independently checked by preparation.

Each role is copied to a relocated path and must keep the same tree digest and pass its runtime and tamper probes.

Every final release path is published with an atomic no-replace rename.

The builder fsyncs the sealed release directory and its parent after publication.

The front-door plan and proof manifest are created without overwrite and fsync their parent directory after their final bytes and mode are durable.

A private durable build journal is written before the first release publication.

Builder workspaces, release staging directories, proof-file staging, worker snapshot staging, and preparation staging all use deterministic names derived from their sealed transaction/publication inputs.
Each directory has an exact ownership marker or journal binding.
Restart removes or completes only an exact attributed partial object; unknown, drifted, or foreign paths are preserved and refused.

Each release contains a build-owned publication marker that binds it to the journal.

A restart removes only journal-attributed, exact-tree, unreferenced partial releases and refuses every unknown or drifted path.

If the durable proof already matches all four exact releases, restart treats the build as complete and removes only the stale journal.

The build journal explicitly records that no live reference changed, so publication recovery cannot authorize a cutover.

## Transaction order

The sealed-adoption transaction accepts only the exact authorized legacy `current` link payloads, the exact legacy Agent Fleet front-door symlink payload, and the exact all-disabled registry bytes.

Forward adoption changes Quota current, Agent Fleet current, the Agent Fleet front door, and the registry in that order.

Interrupted unfinalized adoption rolls backward to both exact legacy links, the exact legacy front-door symlink, and the exact initial registry.

Finalized sealed adoption is irreversible and becomes the old state for the normal cutover transaction.

The normal cutover transaction changes Quota current, Agent Fleet current, the Agent Fleet front door, and the registry in that order.

Normal rollback restores the exact rollback releases, rollback-native front door, and rollback registry before the irreversible post-install boundary.

Both transactions revalidate the quiet point, release bindings, regular-file identity, and live compare-and-swap state immediately before replacement.

That final compare-and-swap is performed after the staged object itself has been rehashed. A live symlink, regular file, registry, or adoption target that changes after the quiet-point scan is never overwritten.

The worker-state gate loads the candidate API through bundle validation, which transitively re-runs the sealed-adoption assessment; provision verification, finalize, and rollback identity attribution all take that path, while the snapshot step revalidates only the cutover quiet point.
The sealed-adoption plan itself stays strict: it accepts live state only at the exact initial or sealed identities.
Once the normal cutover is fully applied and the post-install irreversible boundary is marked, bundle validation instead accepts exactly one further live state - a fully sealed adoption journal, the full quiet-point contract, intact retained sealed release trees, and every adoption-managed path, including the live registry, at its exact cutover-new identity pinned from the reconstructed cutover manifest - reported as the `runtime-switched` phase.
Any other combination, including a post-cutover registry without the marked boundary or with any drifted path, refuses exactly as before.
This pinned post-cutover acceptance exists because the documented order crosses the runtime switch before worker-state verification, so verification, finalize, and rollback attribution must remain provable on the switched machine.

## In-place identity refresh

The prepared activation plan and worker-state manifest pin the live provider-binary identity - inode, mtime, and content SHA-256 - so a byte-exact reinstall of that provider binary gives it a fresh inode and mtime and re-stales both artifacts against the live binary, and the strict activation-plan and worker-state gates then refuse even though the machine is genuinely in the `runtime-switched` state.
A from-scratch rebuild cannot recover, because the `runtime-switched` proof is journal-bound: the post-install irreversible boundary and the sealed-adoption journal live only inside the applying bundle's own `transaction/` directory, cannot be borrowed byte-for-byte by another bundle, and cannot be re-sealed against the already-migrated live registry, so only the bundle that actually applied the switch validates as `runtime-switched`.
The `refresh` subcommand of `prepare_bridge_cutover.py` refreshes exactly those two identity artifacts of that existing bundle in place to the current provider-binary identity, while leaving the sealed cutover and sealed-adoption journals untouched; its `--help` output owns the exact invocation syntax.
It holds the worker-state advisory lock across the journal check and both atomic artifact replacements, so worker-state cannot begin against the old fingerprint during refresh.
It runs only before worker-state verification begins - before the 6a snapshot, while the worker-state journal, snapshot, and snapshot-staging paths are all absent and no worker-state transaction is bound to the manifest.
Once any of those transaction artifacts exists, refresh refuses; it never restarts, resets, concludes, cleans up, or otherwise mutates a worker-state transaction bound to the manifest.
If refresh is interrupted after replacing the bundle but before replacing the worker-state manifest, rerunning refresh repairs the stale manifest and restores an exact pair.
It also refuses unless the bundle is provably the applied `runtime-switched` one - it reuses the same journal-bound phase determination as validation - and it gates completion on a full strict `validate_bundle` that must still report the `runtime-switched` phase, so it makes the strict gates pass only because the recorded identity again equals the live binary, never by loosening any check.

## Exact worker topology

The registry contains eight explicit profiles, but only six profiles are Fleet workers.

The routed worker set is exactly `claude-1`, `claude-2`, `codex-1`, `codex-2`, `codex-3`, and `codex-4`.

Only those six workers may be provisioned, authenticated, identity-bound, enabled, counted as routed capacity, placed in worker pools, probed, or used by canaries.

`claude-3` and `codex-5` are reserves with `safety_policy = "desktop_shared"` and manual-only pools.

The reserve profiles remain disabled, unprovisioned, unauthenticated by Fleet, excluded from worker pools, excluded from routed counts, and untouched by stat, probe, seal, login, logout, or migration actions.

The Codex Desktop session may use `codex-5`, but Bridge never counts or routes that account.

No Desktop login, logout, or relogin is part of Fleet cutover.

Worker-state guards open and read only the exact six routed workers' declared credential guard files.
Credential bytes are hashed in memory for private rollback invalidation and are never copied into snapshots, journals, proof manifests, logs, or public artifacts.
Reserve homes and Desktop-shared homes are never `stat`ed, opened, read, snapshotted, or compared.
Preparation also refuses any reserve home that lexically overlaps a worker home, Agent Fleet identity state, or the worker-snapshot parent.

## Authentication activation contract

The prepared activation plan uses schema version 2 and emits no generated executable command list.

Existing-auth verification and provider-batch identity adoption are browser-free and cannot invoke provider login or mutate credentials.

Manual profile login is available only for the exact six Fleet workers and never names either desktop-shared reserve.

Every manual login requires all same-provider workers disabled, zero same-provider worker leases, the provider maintenance lock, an unchanged registry, and the sealed provider binary.

`profile initialize-login` is the reviewed first-bundle lifecycle and is permitted only while that provider identity bundle is absent.

Initialization records only explicitly initialized workers in a durable provider-scoped provisional batch bound to the exact worker topology and sealed binary.

Each initialization attempt freshly reproves every recorded peer and checks distinctness against same-attempt peers and external identity anchors.

Initialization may commit an incomplete target provisionally, but it publishes the provider bundle atomically and removes the provisional batch only after the complete provider worker set is freshly valid and distinct.

`profile recover-login` is the reviewed recovery lifecycle and is permitted only while the complete provider identity bundle is present.

Recovery requires an existing pinned identity and requires the staged login identity to equal that exact pin, so account replacement is refused.

The activation plan records command shapes for review but keeps every generated command list empty and never executes a login itself.

Browser opening and macOS Keychain interaction require explicit operator flags, and a private browser context is required whenever browser login is selected.

Neither lifecycle reads or changes Desktop identity state, invokes provider logout, or automatically enables a worker or routing.

Local credential changes are transactional, but provider-side token rotation or revocation after login starts may not be locally reversible.

## Verification entrypoint

`tests/bridge-cutover-python.test.sh` is the single Python 3.11 test entrypoint used by both CI and the repository no-mistakes test loop.

`tests/test_build_quota_axi_offline_real_inputs.py` is an opt-in macOS host integration gate.
With its six retained-input variables and two rehearsal-artifact variables set, it uses the real UV CPython 3.11.9 runtime, a retained Node 20 runtime, exact candidate and rollback Git worktrees, and real npm/compiler/dependency closures.
It builds both Quota roles twice without network access, requires the rebuilt package-member maps to equal the retained rehearsal packages, and passes both proofs through the independent sealed-runtime consumer.
Without all variables, CI reports the host-only gate as skipped.

The same host gate accepts exact Agent Fleet candidate and rollback repository, commit, and wheel variables; it archives both commits and requires the independent wheel consumer to match the embedded `tools/agent-fleet` candidate subtree and standalone rollback source exactly.

The macOS-only builder integration and preparation behavior tests skip on Linux, while the transaction and adoption crash matrices and the preparation module's synthetic `agent_fleet.models` schema drift gate run cross-platform.

No routing file, live `current` link, live registry, worker home, credential, browser, or Desktop session is modified by the builder or its unit tests.
