# Firstmate results-first delivery lifecycle

This document describes the results-first delivery path introduced by the
Firstmate/OMX vertical cutover. It is the default for registered projects; the
legacy `no-mistakes` pipeline is preserved as an explicit opt-in only for the
one bounded Firstmate/OMX cutover PR.

## Core idea

A ship task is done only when a validated **delivery receipt** exists at
`data/<id>/delivery-receipt.json`. The receipt proves the change landed and the
post-landing validation, smoke, and rollback/repair steps were run from the
exact landed source.

## Concepts

- **Capability** — what the task must do, acceptance criteria, and authority
  class (`routine` / `destructive` / `irreversible` / `security`).
- **Lane** — exactly one `primary` lease per firstmate home; optional `support`
  leases linked to a primary. Prevents resuming parked GLX initiatives during a
  cutover.
- **Phase** - contiguous lifecycle state: `accepted` -> `implementing` -> `validating` -> `landing` -> `landed` -> `released` -> `deployed` -> `smoke_verified` -> `receipt_finalized` -> `cleanup_eligible`.
  A task can become `blocked` with a recorded reason and resolved timestamp.
- **Evidence** — write-once, hashed, deterministic command output captured by
  `bin/fm-evidence-run.sh`.
- **Receipt** — the immutable, validated JSON record that closes the task.
- **Embargo** — a generation-scoped list of permitted and forbidden task ids,
  used to prevent parked GLX initiatives from resuming during a cutover.

## Tools

| Tool | Purpose |
|------|---------|
| `bin/fm-lane-reserve.sh` | Acquire/release/renew `primary` or `support` lanes. |
| `bin/fm-rollout-embargo.sh` | Manage generation, permitted/forbidden task lists. |
| `bin/fm-delivery-phase.sh` | Start, complete, block, resume, and finalize phases. |
| `bin/fm-evidence-run.sh` | Run a command deterministically and capture hashed evidence. |
| `bin/fm-delivery-receipt.sh` | Validate and finalize a delivery receipt. |
| `bin/fm-delivery-poll.sh` | Byte-static trusted poll for current delivery state. |

## Entry points in existing scripts

- `bin/fm-project-mode.sh` — new projects default to `direct-PR +yolo`; unknown,
  absent, or malformed entries fall back to `direct-PR off`.
- `bin/fm-spawn.sh` - every new ship dispatch creates a private accepted delivery record before launching the worker.
- `bin/fm-brief.sh` - generated ship instructions use absolute Firstmate-owned command and receipt paths.
- `bin/fm-teardown.sh` - refuses teardown unless the receipt is trusted, schema-valid, evidence-valid, mode-matched, and bound to the exact task head when the worktree remains inspectable.
- `bin/fm-crew-state.sh` - finalized receipts and explicit blocks are authoritative, while an in-flight phase is context and worker liveness still requires a run-step or live pane.

## Receipt schema

Receipts use schema `firstmate.delivery-receipt.v1` and are validated by
`bin/fm-delivery-lib.sh`. They contain:

- `task`: id, project, kind, lane, supports, delivery mode, yolo flag.
- `capability`: summary, acceptance criteria, authority class.
- `source`: branch, candidate SHA, merge/PR/local landed identity.
- `phases`: ordered phase transitions with evidence references.
- `validation`, `release`, `deployment`, `smoke`, `rollback`, `provider`:
  applicability-aware sections that may be `not_applicable`.
- `outcome`: terminal status `delivered` and timestamp.

Receipts and in-flight records are never claimed to be redacted.
Evidence publication refuses recognized volatile quota fields and obvious secret assignments instead of silently rewriting retained bytes.

## Deterministic evidence

`bin/fm-evidence-run.sh` decodes one non-empty JSON argv array and executes it directly through a Python subprocess without implicit shell evaluation.
The subprocess inherits the caller environment so project-owned validation and deployment commands retain their explicit runtime authority.
Known shell interpreters are refused as the executable, stdout/stderr/exit code and immutable metadata are staged privately, and the complete bundle is atomically published with a deterministic `MANIFEST.sha256`.
The manifest digest recorded in a phase hashes the exact manifest bytes; receipt validation re-hashes every listed file and checks the evidence candidate SHA.

## Rollout embargo

During a cutover, `bin/fm-rollout-embargo.sh` is a standalone operator control for permitted and forbidden task ids.
Dispatch integration and stronger concurrent lease or embargo mutation guarantees remain post-canary follow-up and are not claimed by this bounded repair.
