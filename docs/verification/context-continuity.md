# Context continuity verification

The [context continuity policy](../context-continuity.md) owns supported behavior and its limits.
This record covers the optional Rust journal and its Codex app-server probe; existing fleet launch adapters, supervisor hooks, Desktop threads and other harnesses are unchanged.
The probe requires a real installed Codex, credentials and a named Herdr lab, and spends model tokens only when explicitly run.
Portable CI runs the Rust behavior tests without credentials.

## Portable checks

Run from the repository root:

```sh
cargo test --locked --manifest-path rust/context-continuity/Cargo.toml
cargo fmt --manifest-path rust/context-continuity/Cargo.toml --check
cargo clippy --locked --manifest-path rust/context-continuity/Cargo.toml --all-targets -- -D warnings
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

On 2026-09-24 with Rust 1.98.0, the behavior suite reported `25 passed; 0 failed`.
It exercises the public library and CLI, with corruption planted in SQLite through an independent connection.
The crash case waits for a real child process to report its uncommitted write on stdout, kills it, and verifies rollback before a successful retry.
A second in-process opener and a separate CLI process are both refused while a writer owns the lock, and a reopen succeeds after it releases.
Other negative controls cover stale source bytes, expired/future checkpoints, oversized retrieval, duplicate obligations, symlinks/traversal, secrets, incompatible model/host/backend/pane/thread identities, changed legacy consent/provenance, replay and receipt corruption, uncertain effects, backup collisions, bare relative backup and migration destinations, schema incompatibility, and missing/stale/cumulative telemetry.
The launcher dry runs use an empty `PATH`, so they cannot silently invoke Codex; one confirms a dash-led prompt is passed after a `--` option terminator.
Native config controls cover dry-run nonmutation, exact preservation of all original bytes, private backup, atomic replacement and rollback, stale preimages, later edits, wrong backup hashes, existing threshold/profile conflicts, model mismatch, lock contention and symlink refusal.

## Native refresh procedure

The implementation is [`native-probe.rs`](../../rust/context-continuity/examples/native-probe.rs), with all probe logic in Rust.
Use the generated Herdr-lab contract supplied with the task for provisioning, every native command and teardown.
Never run this probe in the default session, substitute ambient `HERDR_SESSION` for helper scoping, or restart a shared Codex server.
The helper's unchanged-default-session tripwire remains mandatory.

Build `cargo build --locked --manifest-path rust/context-continuity/Cargo.toml --examples`, then create an unused private evidence directory.
Inside the provisioned lab, create a workspace with the helper, read its `root_pane.pane_id` and `root_pane.terminal_id`, and run the example binary in that pane with:

```text
native-probe <evidence-directory> <generated-lab-session> <terminal-id> --threshold-stimulus
```

The evidence directory and binary must be absolute paths from the isolated task worktree.
Use helper-mediated `pane wait-output` for `NATIVE_CONTINUITY_(PASS|FAIL)` with a bounded timeout, then read `proof.json` and complete the required teardown.
A failure or missing proof is not a pass even when a CLI command returns success.
The probe fails outside the named lab and uses only ephemeral Codex threads with task-local SQLite and log paths, disabled hooks/plugins/apps/memory/shell tools, and read-only model permissions.
It denies app-server requests for interactive approval or tool execution.
It checks the effective native configuration, real model identity, compaction completion, process exit, distinct fresh thread, exact synthetic obligation/receipt readback and acknowledgement suppression.
The threshold stimulus adds repeated inert text, verifies provider-reported input usage reached the threshold, requires automatic compaction before any manual compaction call, and then checks a small turn with cumulative usage over the threshold does not cause another automatic compaction.
No fixture fabricates a vendor token event or substitutes for that native test.
Replacing `--threshold-stimulus` with `--config-readback` performs only native configuration reads in three fresh processes: ambient settings, the proposed compaction overrides, and those same overrides with an alternative model.
It emits selected model/threshold/scope fields and isolated runtime paths; it never copies the user's full configuration or sends a model request.
The separate `--lower-context-control` mode keeps the threshold at 230000 but supplies a smaller 32000-token context window and bounded inert input, requiring native automatic compaction below 230000 to verify the runtime's lower-window cap.

## Measured native support

On 2026-09-24, Codex CLI 0.156.0 and Herdr client/server 0.9.0, protocol 22, ran the native probe on Fedora Kinoite 44 with a Toolbx shell.
Native Herdr identity was `session + pane_id + terminal_id`; a pane ID had the shape `w1:p1`, and its terminal incarnation had the shape `term_…`.
`HERDR_PANE_ID` supplied the pane ID, while `terminal_id` came from that same pane's API response.
Neither a Zellij numeric index nor an invented UUID was used.

The first small request reported 8553 input tokens and 8563 total request tokens, with no compaction.
The configured threshold and scope read back as `230000` and `total`.
The threshold stimulus reported 243589 input tokens and 243600 total request tokens; cumulative usage was 252163.
Before the next response, a completed `contextCompaction` item was observed without a preceding manual request.
The post-compaction update reported `last.totalTokens=64367`, zero input/output subtotals, and unchanged cumulative usage of 252163.
The next real request reported 136811 input tokens; this discrepancy establishes that the reset update is not an exact next-request active-context measurement.
A further small request reported 136834 input tokens and cumulative usage of 525827, without another automatic compaction.
A later explicitly marked manual compaction completed successfully and reported a synthetic reset estimate of 64371.
The source process then exited, a new process created a distinct ephemeral thread, and the fresh model returned exactly `verify-evidence|published-fixture|confirmed` from the bounded checkpoint.
Replaying after acknowledgement emitted no checkpoint body.

These observations establish working native threshold configuration, automatic compaction after a sampled threshold crossing, manual compaction completion and synthetic fresh-process recovery.
They do **not** establish exact action at token 230000, reconstruction of every token of a real working conversation, completeness of a real stow pass, or exactly-once external effects.
Firstmate watcher arm/turn/wake/drain/handle/generation-bound acknowledgement/rearm continuity and full supervisor restart recovery remain unverified by this probe.
The native runtime checks between operations, and the observed input overshot the configured mark.
The journal therefore retains early-checkpoint headroom and an explicit telemetry-gap result instead of claiming an exact autonomous reset.
Raw task-specific proof, thread identifiers and filesystem paths belong in the private evidence report rather than this reusable record.

The native configuration control read ambient model `gpt-6-astra` with both compaction keys unset.
Explicit overrides read back `230000` and `total`; selecting `gpt-6-sol` retained those same compaction overrides.
This proves the keys are not scoped by model selection, and does not prove that a proposed user-config patch has been deployed.

The separate smaller-window control read back `model_context_window=32000`, threshold 230000 and scope total, while native usage reported a usable window of 30400.
Its 29589-input-token request was followed by automatic compaction before any manual request, well below the configured 230000 mark.
The following request still used 29854 input tokens, so another compaction in that constrained scenario is not a valid cumulative-only negative control.
The full-window experiment above remains the cumulative-only control.
This observed lower-window cap agrees with the versioned [Codex 0.156.0 model-limit implementation](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/protocol/src/openai_models.rs), which caps the configured limit against a known model context window.
It does not certify arbitrary providers with incorrect or missing context metadata.

After an explicitly authorized native-global configuration adoption, a fresh isolated process read the ambient model as `gpt-6-astra`, threshold 230000 and scope total without compaction overrides.
The guarded Rust operation verified the original file hash, saved a private backup beside its owner, preserved every existing byte, performed atomic replacement and passed rollback dry-run validation.
That evidence covers later processes loading the native user configuration; it does not assert adoption by already running or remote app-server processes, other harnesses, or calls supplying higher-precedence overrides.
Machine-specific configuration and backup paths remain in the private deployment receipt.
