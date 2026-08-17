# Prompt runtime verification

This maintainer-verification record owns current empirical evidence for progressive disclosure, role compilation, compact skill discovery, guarded mutation disclosure, and prompt-overlay reconciliation.
Stable architecture and ownership boundaries live in [`docs/prompt-runtime.md`](../prompt-runtime.md).
The phase-one exhaustive physical-line manifest is [`prompt-disclosure-manifest.json`](prompt-disclosure-manifest.json).
The versioned multi-generation owner is [`prompt-lineage.json`](prompt-lineage.json), which binds immutable historical objects separately from current live-authority bytes and marks prototype history non-authoritative.
Complete pinned measurements are [`prompt-disclosure-measurements.json`](prompt-disclosure-measurements.json).

## Preservation and current authority

Phase one maps all 286 changed or removed physical lines from `a218ebc497af996e04f2aa8d4b8dbd569d4b882a`, including blank and fence lines, into seven deferred semantic owners.
Generation one binds that manifest and its exact Git object at `1eaf368439465d4338656d760886b8b28b138bc9`.
Generation two binds upstream semantics at `88d0f2e2f8474334ed5ba85913d1295ea5fa6251`.
Generation three binds current authority by exact path and SHA-256, explicitly records the generated-parity upstream commit, hashed upstream text, and hashed self-contained source archive, and inventories every tracked overlay path.
Overlay planning requires the recorded compatibility baseline to equal the plan's previous upstream, while candidate verification independently requires the newer selected upstream to be the candidate's sole parent.
The preservation and generated-parity proofs are self-contained in hashed repository artifacts for the baseline, transformed bundles, exact upstream text, and fixed source archive, so they do not require the historical generation commits or upstream Git object to remain available locally.
Historical commits remain provenance and are never prompt, documentation, or current-authority inputs.
`bin/fm-instructions.sh verify` rejects missing or changed lineage artifacts, malformed lineage, unmapped phase-one lines, duplicate ownership, changed current-authority bytes, coordinated live-authority hash refreshes, changed fixed upstream artifacts or bindings, dead triggers, broken links, and generated-surface drift.

## Role and skill loading

`bin/fm-prompt-compile.py` deterministically compiles primary, secondmate, Firstmate ship, Firstmate scout, and non-Firstmate project-worker surfaces for Pi, and the Pi-backed persistent secondmate launch consumes its boundary composed with the exact selected charter.
`tests/fm-spawn-dispatch-profile.test.sh` proves that launch consumes the composed charter from its per-launch prompt directory, tightens a current-user-owned legacy task temporary parent to mode `0700`, and refuses symlinked or foreign-owned parents before writing the prompt.
It refuses non-Pi live loading, unsupported secondmate runtimes, worker briefs with primary startup or fleet-supervision language, a missing ship delivery contract, and a non-Firstmate worker carrying Firstmate tracked-material instructions.
All 19 internal skill names and bodies are unchanged from upstream except for their compact descriptions.
The descriptions retain explicit load triggers and remain under Pi's 1,024-character limit.

The real offline command is:

```sh
bin/fm-prompt-pi-offline-check.sh
```

On 2026-08-14 with Pi 0.84.1 it produced:

```text
PASS Pi offline loader: compiled primary prompt and 19 compact skills loaded; provider request aborted
```

The check invokes an extension command, reads Pi's structured prompt options, compares the exact compiled custom prompt and all discovered names/descriptions, and uses a provider-request sentinel.
Because extension commands bypass the agent loop, the check performs no provider work.
No live loader claim is made for another harness, and Codex remains structurally isolated to the no-mistakes gate.

## Guarded mutation disclosure

`tests/fm-prompt-phase2.test.sh` exercises disclosure through the public compiler and receipt interfaces.
Positive coverage issues and consumes an exact spawn receipt with the same bound mutation directories.
It also proves that a non-default receipt lifetime survives validation and that an authorized control relaunch can issue one exact replacement-spawn receipt, while concurrent handoff attempts issue exactly one receipt and the handoff cannot be replayed or authorized by an exit receipt.
Negative coverage refuses missing, malformed, stale-instruction, argument-mismatched, task-mismatched, cross-home, mutation-directory-mismatched, expired, and replayed receipts, caller-controlled test and internal-route markers without matching process ancestry, caller-selected test roots or process-inspection tools, trusted script paths placed only in ancestor arguments, forged relative executable names even from the repository working directory, relative script operands from foreign working directories, and a production batch spawn without its outer receipt.
The batch refusal is checked before the watcher guard runs, while `tests/fm-spawn-batch.test.sh` continues to prove that the public batch path re-executes and reports every pair.
The local-merge public owner is additionally run with a fake Git binary to prove a missing receipt refuses before Git executes.
Existing operation guards remain independently covered by their focused suites.

## Overlay reconciliation

`tests/fm-prompt-overlay.test.sh` builds real divergent-history Git fixtures.
The safe overlay case confirms the final diff is fully inventoried, preserves an unrelated upstream edit, retains registered ownership after an upstream correction converges to the same entry, preserves executable mode `100755`, creates a candidate with the exact upstream as its sole parent, and reaches readiness only with the exact verification token.
`tests/fm-update.test.sh` additionally drives the public updater through a real semantic refresh: an upstream `AGENTS.md` addition lands exactly once in its deferred optimized owner, an upstream skill-body addition lands with the compact discovery description intact, and the installed refs remain unmoved until approval.
Its negative semantic fixture proves a hash-bound old `AGENTS.md` cannot mask an unmapped change: the unresolved owner is reported and no readiness line or ref movement occurs.
The history-aware case separates an older semantic provenance baseline from the actual shared Git base, places two local commits above that base, and proves an inherited `.github/workflows/ci.yml` timeout plus a later upstream-only pointer edit remain upstream-owned without ambiguity.
The installed-overlay exercise also proves the explicitly composable `docs/scripts.md` owners are disjoint: the overlay updates the updater entry while upstream updates the `CLAUDE.md` pointer entry.
`tests/fm-update.test.sh` additionally exercises the installed graph shape of an old pinned upstream parent, the actual optimized overlay commit, a stale live ref, and newer upstream commits; it proves that compatible reconciliation moves no installed ref before exact approval and that approved installation atomically records the new live and prior rollback commits.
Negative cases refuse dirty input, divergent edits to one semantic owner, multiple best shared Git bases, stale readiness, a missing object, malformed policy, an unrelated commit graph, an unregistered local commit, a mismatched pinned generated-parity baseline, an altered saved plan, a symbolic candidate ref, a lineage graph outside the repository, and a tracked lineage graph that differs from the selected overlay commit.
The update-path conflict fixture proves that a genuinely ambiguous overlay/upstream owner moves neither `main` nor the live ref.
An absent or refusing disclosure owner leaves the index, objects, and refs unchanged, including when a Git cleanliness inspection could otherwise refresh the index.
No test or production interface merges, rebases, stashes, forces, resets a working branch, or chooses ours or theirs.
The candidate ref remains separate from `main`, and readiness reports the previous overlay for rollback without installing the candidate.

## Measurements

Measurements were refreshed on 2026-08-14 with Python 3.13.7, pinned `tiktoken==0.11.0`, `o200k_base`, and `cl100k_base`.
The exact command is:

```sh
uv run --python 3.13 --with tiktoken==0.11.0 bin/fm-instructions-measure.py --output docs/verification/prompt-disclosure-measurements.json
```

`tiktoken` has no exact mapping for the selected provider-specific model, so both encodings are approximations rather than billing evidence.
The artifact separates the initially loaded primary file, compact skill catalog, disclosed common paths, directly reachable corpus, generated briefs, and assumptions.
It excludes vendor prompts, dynamic private startup data, tool schemas, general maintainer documentation, and project context outside Firstmate.
No provider cache-read, cache-write, billing, or provider-latency claim is made.

Against current unoptimized upstream, initially loaded `AGENTS.md` falls from 13,805 to 6,591 `o200k_base` tokens and from 13,809 to 6,595 `cl100k_base` tokens.
The status-only path is 6,591 `o200k_base` tokens, ordinary intake is 11,301, recovery is 9,707, and merge or cleanup is 9,533.
The bounded directly reachable corpus is 81,706 `o200k_base` tokens, 48 fewer than current unoptimized upstream under the artifact's explicit definition.
Canonical generated briefs total 3,308 `o200k_base` tokens and are reported separately because they load only for the launched role.

## Maintainer commands

```sh
bin/fm-instructions.sh verify
bin/fm-prompt-pi-offline-check.sh
bin/fm-test-run.sh tests/fm-instructions.test.sh tests/fm-prompt-phase2.test.sh tests/fm-prompt-overlay.test.sh tests/fm-update.test.sh
bin/fm-test-run.sh tests/fm-brief.test.sh tests/fm-supervision-instructions.test.sh tests/fm-sessionstart-nudge.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-task-delivery.test.sh tests/fm-gate-refuse.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
python3 -m py_compile bin/fm-instructions-measure.py bin/fm-instructions-verify.py bin/fm-operation-disclosure.py bin/fm-prompt-compile.py bin/fm-prompt-overlay.py bin/fm-prompt-semantic-refresh.py
bash -n bin/fm-operation-disclosure-lib.sh bin/fm-prompt-pi-offline-check.sh

git diff --check
```
