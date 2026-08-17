# Prompt runtime and overlay architecture

This maintainer reference describes the stable ownership and extension boundaries for optimized Firstmate prompts.
Exact command syntax remains in each executable's header and `--help` output.
Current empirical measurements and lineage evidence live in [`docs/verification/prompt-disclosure.md`](verification/prompt-disclosure.md) and [`docs/verification/prompt-lineage.json`](verification/prompt-lineage.json).

## Semantic ownership

`AGENTS.md`, the deferred `FIRSTMATE_*.md` bundles, generated worker briefs, and individual skill bodies remain the semantic owners of their contracts.
The role compiler owns composition and role refusal, not a second copy of those procedures.
The secondmate boundary in `.agents/prompt-roles/secondmate.md` owns only the differences between a main Firstmate and a persistent routed secondmate.
Historical commits and lineage records are provenance and can never be loaded as live authority.

## Role compilation

`bin/fm-prompt-compile.py` is the compilation owner.
Live compilation is deliberately Pi-only because Pi is Firstmate's active loader, while Codex remains isolated to the no-mistakes gate.
Primary compilation loads the optimized `AGENTS.md`; Pi-backed persistent secondmate launches compile their dedicated boundary with the exact selected charter; ship, scout, and non-Firstmate workers compile their exact generated brief.
The secondmate launch accepts only a current-user-owned, non-symlink task temporary root, tightens an accepted legacy root to mode `0700`, and then writes the composed prompt beneath a fresh unpredictable directory inside it.
It refuses a symlinked or foreign-owned root before writing the prompt.
Unsupported role, runtime, or harness combinations are refused rather than falling back, and every non-primary output is checked for primary-only startup, fleet-supervision, and captain-contact language.
Other harness and runtime integrations retain their current transports and structural tests without acquiring unsupported live-loading claims.

## Disclosure-bound mutation precondition

`bin/fm-operation-disclosure.py` owns the receipt format and validation state machine.
Role runtimes identify themselves with `FM_PROMPT_ROLE`, and guarded public mutations always require a receipt.
Receipt issuance authenticates no issuer: any same-user process with access to the home can mint one, so a receipt is a one-use disclosure-binding precondition rather than an authenticated capability or independent authority boundary.
Only the repository test runner can enable the explicit test-only bypass when its test-mode marker, recorded process identity, and verified process ancestry all match.
Test-runner ancestry recognizes only a trusted shell whose script operand resolves to the exact repository runner, resolving a relative operand against that process's observed current working directory and reading process identity through fixed system executables rather than caller-selected tools or command text.
Arbitrary-argument references, forged executable names, and relative operands that resolve elsewhere grant no test authority.
Internal lifecycle routes issue receipts bound to each exact child invocation instead of accepting caller-declared route markers.
A production batch spawn consumes one outer receipt before dispatch, then issues one exact receipt for each child spawn.
A receipt binds one operation to the exact home, effective state, data, config, and projects directories, task, role, argument vector, current disclosure bytes, issue time, expiry, and nonce, and is valid only while the current time is strictly before that expiry.
The spawn, PR merge, local merge, cleanup, and lifecycle-control owners consume that receipt atomically after closed argument validation and before their existing locks or mutation paths.
Overlay rebuild consumes its exact receipt after closed candidate-ref validation and before any Git cleanliness inspection, plan load, or candidate mutation.
A control-authorized relaunch may hand its consumed receipt to the replacement spawn exactly once by atomically retiring the control receipt and issuing a new receipt bound to the same home, task, role, repository root, and relaunch invocation; no other internal handoff is authorized.
The receipt adds a precondition and never replaces any operation's existing authority, landed-work, clean-tree, identity, fast-forward, or provider checks.

## Upstream reconciliation

`bin/fm-prompt-overlay.py` composes around the ordinary-mirror fast-forward owner in `bin/fm-update.sh`; it does not weaken that contract.
The default branch normally remains an upstream mirror, while an explicitly installed optimized prompt is a verified single-parent overlay whose installed commit may intentionally diverge from the next fetched upstream.
Reconciliation keeps the pinned compatibility baseline as semantic provenance and authority validation, but derives the unique actual Git merge base of the fetched upstream and installed overlay for path ownership and three-way composition; it never assumes that `refs/firstmate/overlays/live` is newer or more authoritative than checked-out `main`.
This history-aware ownership boundary supports multiple local overlay commits while classifying changes inherited before the shared base as upstream-owned rather than overlay-owned.
`bin/fm-prompt-semantic-refresh.py` is the deep transformation module at the instruction seam.
Ruby with Psych is a supported runtime dependency for its YAML-semantic skill-frontmatter boundary; bootstrap reports missing Ruby separately from an installed Ruby whose Psych library cannot load.
Its single refresh interface diffs `AGENTS.md`, internal skills, and role instructions from the lineage-bound upstream generation to the selected upstream, then emits a canonical transformation only when each change has exactly one optimized owner.
For `AGENTS.md`, unchanged semantic context must locate one always-loaded or deferred owner and the resulting text must occur exactly once.
Skill refresh takes the new upstream body and metadata, preserving the overlay description only for paths explicitly registered as compact-description owners and otherwise taking the upstream description.
Psych validates the complete YAML scalar boundary, including multiline forms; malformed, duplicated, noncanonical, or otherwise unproven descriptions stop before candidate construction.
Unmapped additions, ambiguous context, removals without one owner, new instruction surfaces without a proven policy, and role leakage likewise stop rather than selecting the old overlay file.
The same proof emits refreshed upstream artifacts, generated-role parity input, lineage, and live-authority hashes, so those bindings can change only as outputs of a complete reconstruction.
The updater, overlay planner, verifier, and documentation call or describe that interface rather than reimplementing semantic ownership.
Separately registered documentation-composition paths preserve both owners only when their changes from the actual shared base are disjoint.
Multiple best merge bases, overlapping non-instruction edits, unbound same-path authority, binary or mode changes, stale lineage, and malformed ownership records remain ambiguous and stop before rebuilding.
The tool never rebases, stashes, forces, resets a branch, or chooses ours or theirs, and its bounded disjoint composition is recorded in the canonical plan rather than delegated to Git's merge policy.
A safe rebuild uses a private temporary Git index, preserves exact object modes, creates a single-parent candidate commit whose parent is the exact upstream commit, rejects symbolic candidate refs, and updates the named ref without dereferencing it.
The tracked lineage graph must remain inside the repository, be present in its own complete path inventory, and match the exact graph stored by the selected overlay commit.
Its live-overlay generation binds the fixed generated-parity compatibility baseline, and reconciliation requires that binding to equal the plan's previous upstream rather than the newer selected upstream.
Legacy preservation verification fixes the original live-authority inventory and binding.
A later binding is accepted only when the semantic refresh can be reconstructed from its immutable previous-upstream, selected-upstream, and producer-overlay provenance and every emitted owner byte matches the candidate.
When review hardens the transformer after candidate construction, the lineage attestation additionally binds the exact single-parent candidate and evidence, a descendant reviewer commit and transformer hash, and the only permitted lineage additions; verification reconstructs and compares the candidate generation while rejecting circular producer ancestry or unattested drift.
Every plan-consuming stage reconstructs the canonical plan from its bound commits and repository lineage, so a saved plan cannot change overlay ownership or other reconciliation inputs after planning.
Verification recomputes the tree and graph, and readiness binds the exact candidate, upstream, canonical plan, and checks while reporting the actual installed overlay for rollback.
The ordinary `bin/fm-update.sh` entrypoint prepares a compatible candidate without moving installed refs; its explicit installation form re-verifies the token, origin, clean tree, branch, and installed overlay, then updates `main`, the working tree, the live ref, and the rollback ref as one approved transition.
The exact candidate named by the updater still requires separate explicit installation approval, and any failed verification or ref transaction leaves the prior installation authoritative.
