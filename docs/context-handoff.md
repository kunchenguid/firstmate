# Curated Claude/Obsidian context handoff

The context handoff is a default-off local bridge from already-curated Firstmate or Claude facts to one exact authorized Claude/Obsidian curator.
It is not transcript capture, a compaction-summary archive, or an alternate memory policy.
[`AGENTS.md`](../AGENTS.md) remains the owner of most-specific knowledge routing, and the internal [`stow` skill](../.agents/skills/stow/SKILL.md) remains the owner of its curation pass.

## Safety boundary

Only `decision`, `preference`, `gotcha`, `project-fact`, `next-step`, and `pointer` items can enter the register.
Each item carries one bounded plain-text statement, an approved no-symlink source path, the source file's exact SHA-256, confidence, sphere, an exact sensitivity class, destination provider class, explicit supersession IDs, and the SHA-256 of an exact reviewed registration eligibility contract. Only `ordinary-project-context` is eligible; `financial-data`, `customer-record`, and `personal-address` are closed, explicit refusal classes, with deterministic high-confidence content checks as a second boundary.
The register rejects raw chat, transcripts, generated compact summaries, model reasoning, tool streams, reports copied wholesale, terminal output, credentials, financial data, customer or order records, addresses, email or message bodies, sensitive material, and local-only material. Save preparation independently requires the same exact sensitivity classification for every write path and refuses every class except `ordinary-project-context`.
The producer proposes a handoff candidate only after the fact has been written to its ordinary durable owner.
Claude remains the sole final relevance, duplicate, and Vault-routing authority.

[`claude-obsidian.handoff.v1.schema.json`](../schemas/claude-obsidian.handoff.v1.schema.json) is the authoritative envelope schema.
[`libexec/fm-context-handoff.py`](../libexec/fm-context-handoff.py) is the single mechanics owner for candidate records, sealing, receipts, queue states, delivery, hook handling, approval bindings, transaction verification, and source acknowledgements.
The supported Bash entrypoint [`bin/fm-context-handoff.py`](../bin/fm-context-handoff.py) exposes its commands, and the entrypoint plus engine `--help` own exact command and path mechanics.

## Durable lifecycle

A Pi `session_before_compact` handler seals only candidates already in the register for the current Pi session.
The handler never reads or serializes Pi branch entries, messages, summaries, reasoning, or tool output and never calls a model.
A producer response that identifies a non-empty register that could not be sealed durably stops compaction and leaves a failure receipt.
A Pi adapter launch, nonzero-exit, malformed-output, output-cap, or ten-second timeout failure also terminates the child and stops compaction even when no receipt can be written.
Empty and disabled registers do not stop compaction when the adapter completes successfully, including when the active Vault or endpoint binding is unhealthy and nothing is pending.
The paired `session_compact` and `session_compact_failed` handlers bind the terminal outcome to the complete bounded set of retryable and newly sealed records in that attempt and never infer success from the success event alone.
A configuration or active-binding failure at seal time still writes the durable non-empty failure receipt before cancelling compaction.
Each terminal outcome persists the complete attempt result before any per-record queue transition, so a crash mid-attempt is replayed idempotently instead of leaving records reachable by an opposite outcome.
An attempt journal that no longer reads back as its own exact record is quarantined with its observed digest and retired, so a corrupt artifact cannot wedge sealing, outcome recording, or delivery.

The seal uses a content-bound stable ID, canonical JSON, a mode-0600 temporary file, file fsync, create-only atomic publication, serialized durable creation and fsync of every new state-directory entry, durable repair of non-private directory modes without repeatedly syncing unchanged directories, directory fsync including recovery of an identical publication, a queue published before claims, a 32-item cap, and a 32-KiB envelope cap.
A candidate record binds its own stable ID to the registering harness, session generation, and item bytes, so a retargeted candidate cannot be sealed into another session's attempt.
A retry recovers valid orphan envelopes, missing queues for claimed records, and incomplete claim sets without resealing different bytes.
Sealing selects the deterministic candidate-ID prefix that fits both caps, preserves every remaining candidate identity for a later attempt, and drains a full retry set before sealing more candidates.
Registration applies bounded backpressure to retryable records and unsealed candidates, so a reachable sequence of successful attempts always drains the register.
Sealed envelopes, queue state, receipts, approval records, transaction bundle staging, quarantine records, and acknowledgements remain below `state/context-handoff/` in the effective Firstmate home and never enter the Vault.
Disabling the feature leaves every one of those records intact.

Delivery reads the local queue first.
It addresses only the configured Herdr session, workspace, tab, pane, Claude agent identity, and hashed Claude session generation.
It additionally verifies the selected Vault's canonical path and directory object and requires the agent's current and foreground directories to equal that Vault.
A cwd match alone never selects a recipient.
Unavailable, busy, dead, changed, or ambiguous recipients leave the record pending with a reason.
The bridge never starts, restarts, substitutes, discovers, or inspects a Claude process.
A notification may submit only the constant `/firstmate-context-handoff:consume`, never a record ID or record content, through a Herdr operation that atomically rejects a changed agent-session generation.
When the installed Herdr protocol exposes no such precondition, delivery retains the record pending without submitting a prompt.

## Claude consumer

[`integrations/claude-context-handoff`](../integrations/claude-context-handoff/) is the versioned Claude plugin artifact.
It supplies `PreCompact`, `PostCompact`, `SessionStart`, `StopFailure`, and `PreToolUse` handlers, one disabled-by-default consume skill, and one local stdio MCP server.
The lifecycle adapter ignores `transcript_path` and `compact_summary`.
Claude `PreCompact` seals only the separately registered Claude candidates for the configured session generation, durably binds that exact attempt across hook processes and retries, and calls no model.
An exact matching session with an unhealthy endpoint or Vault binding writes a failure receipt and blocks compaction while genuinely foreign sessions remain ignored.
The exact live Claude generation is revalidated inside the same serialized transition that seals and publishes the attempt binding, so an endpoint replaced after the initial probe blocks without sealing.
The Herdr probe budget stays materially shorter than the `PreCompact` hook timeout, leaving margin to publish the failure receipt and return the block decision before Claude can terminate the hook.
Session-start publication is serialized and generation-monotonic, so a retired hook process cannot replace a newer process capability or restore stale MCP authority.
Post-compact and session-start reporting exposes only bounded counts and generic next action, not record contents, and counts only the records the MCP consumer can actually claim.

The consumer revalidates the canonical envelope, item and byte caps, source hashes, source allowlist, provider class, sensitive categories, exact Vault object, queue hash, exact Herdr environment, and Claude session binding before showing one record to Claude.
Claude may record `duplicate`, `not-durable`, `not-allowed`, or `needs-captain` as durable dispositions.
Automatic apply authority covers exactly one new note under a configured create prefix plus the configured coupled index, log, and hot replacements in one `operation_type: save` bundle.
Deletion, move, canonical note replacement, merge, `.obsidian`, Git, GitHub, executable installation, credentials, sensitive content, ambiguity, and out-of-contract paths are quarantined.

The consumer deterministically maps the handoff record ID to one transaction operation ID.
It stages canonical bundle bytes privately, verifies a reviewed manifest covering the entrypoint and every Python file in the installed transaction package, executes a private snapshot of those exact bytes for `inspect`, and stores the returned Vault-bound approval SHA-256 plus manifest identity.
Commit accepts only the currently active bundle and approval while the record is pending or notified, invokes `claude-obsidian.transaction.v1` once, verifies the complete mode-0600 journal and result, every changed-path hash, complete journal state, exact bundle and approval correlation, and the absent mutation lock, and only then writes the source acknowledgement before transitioning the queue terminal.
An identical retry is idempotent, changed handoff payload bytes quarantine, terminal dispositions revoke every prepared Save, and apply-complete-before-ack or acknowledgement-before-queue crashes heal from the verified transaction result or durable acknowledgement before any conflicting disposition can publish.
Exit 75 leaves the record pending for a fresh read, rebuild, and inspect.

The `PreToolUse` guard denies direct Write, Edit, NotebookEdit, shell mutation, unrelated MCP mutation, delete, move, Git, GitHub, installation, and credential tools in the curator session.
Only the five exact tools exported by the bundled `firstmate-context-handoff` MCP server pass that MCP guard boundary, and every mutation-capable one also requires the current hook session, process capability, and exact live Herdr generation.
Save mutation is available only through the serialized MCP commit path, which holds the consumer state lock while revalidating the current hook session's process capability, exact live Herdr generation, source bytes, queue state, active private bundle, approval, and terminal state.
The installed transaction core remains the primary confinement and recovery boundary because Claude command hooks cannot make their own startup or timeout infallible.

## Default-off configuration

Copy [`examples/context-handoff.json`](examples/context-handoff.json) to local `config/context-handoff.json` only after replacing every placeholder with reviewed local metadata.
The four independent booleans are `registration_enabled`, `sealing_enabled`, `delivery_enabled`, and `consumer_enabled`.
The example keeps all four false.
The configuration stores no credential and must identify exact approved source roots, source/statement/classification eligibility contracts, provider classes, Vault path/device/inode, Herdr endpoint and session hash, Python executable, transaction dependency root and complete reviewed file manifest, create prefixes, coupled replacement paths, and required coupled paths.
Registration is a closed allowlist: every contract binds the canonical source path and hash, statement hash, kind, confidence, sphere, provider class, and supersession set before the CLI can accept the candidate.

Do not enable the real Vault as part of installation.
A later local activation must complete this checklist in order:

1. Land and fast-forward the reviewed Firstmate change.
2. Back up the selected Vault and verify the backup readback.
3. Reconcile every current Vault writer without discarding work.
4. Record the canonical Vault device and inode and the exact existing Herdr Claude endpoint and session-generation hash.
5. Record fresh SHA-256 values for Herdr and a complete manifest containing the transaction entrypoint plus every Python file below the installed transaction package.
6. Run the focused synthetic suite and the model-free Pi and Claude hook smokes on the landed bytes.
7. Load the plugin explicitly from its landed directory with a Vault-scoped Claude configuration.
8. Record reviewed exact eligibility contracts, start with registration only, then sealing, then the consumer guard, and enable delivery last.
9. Re-run hook discovery, exact endpoint probing, guard denial checks, serialized MCP commit checks, and a synthetic transaction readback before any real record is admitted.
10. Keep the first real record pending for manual inspection before granting the approved standing Save authority.

## Disable and rollback

Set `sealing_enabled`, `delivery_enabled`, and `consumer_enabled` to false to stop new seals, notification, and curation.
Set `registration_enabled` to false as well when no new proposal should enter the register.
Stop loading the versioned plugin to remove its hooks and MCP tools after the switches are off.
Rollback code or configuration only after inspecting pending queue reasons and transaction results.
Never delete filed notes, sealed records, pending records, receipts, quarantine records, results, or acknowledgements automatically.
Never stop or restart Herdr, Pi, Claude, or Obsidian as a handoff rollback action.

## Verification

Run `tests/fm-context-handoff.test.sh` for deterministic registration, sealing, delivery, guard, transaction recovery, backpressure, durability, and bounded-transport coverage.
Run `tests/fm-pi-primary-types.test.sh` for the installed Pi extension type contract.
Run `claude plugin validate integrations/claude-context-handoff` for model-free plugin discovery validation.
[`verification/context-handoff.md`](verification/context-handoff.md) records the current installed-version and official-document evidence.
