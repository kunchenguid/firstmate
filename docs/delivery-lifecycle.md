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
- **Phase** — monotonic lifecycle state: `accepted` → `implementing` →
  `validating` → `landing` → `landed` → `released` → `deployed` →
  `smoke_verified` → `receipt_finalized`. A task can become `blocked` with a
  recorded reason and resolved timestamp.
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
| `bin/fm-delivery-poll.sh` | Byte-static trusted poll for delivery state changes. |

## Entry points in existing scripts

- `bin/fm-project-mode.sh` — new projects default to `direct-PR +yolo`; unknown,
  absent, or malformed entries fall back to `direct-PR off`.
- `bin/fm-brief.sh` — ship definition of done now stops only at a finalized
  receipt.
- `bin/fm-teardown.sh` — refuses to tear down a results-first task without a
  finalized receipt.
- `bin/fm-crew-state.sh` — authoritative state for delivery tasks comes from
  `state/<id>.delivery.json`.

## Receipt schema

Receipts use schema `firstmate.delivery-receipt.v1` and are validated by
`bin/fm-delivery-lib.sh`. They contain:

- `task`: id, project, kind, lane, supports, delivery mode, yolo flag.
- `capability`: summary, acceptance criteria, authority class.
- `source`: branch, candidate SHA, merge/PR/local landed identity.
- `phases`: ordered phase transitions with evidence references.
- `validation`, `release`, `deployment`, `smoke`, `rollback`, `provider`:
  applicability-aware sections that may be `not_applicable`.
- `outcome`: status (`delivered` / `blocked` / `failed`) and timestamp.

Receipts and in-flight records are redacted for volatile provider fields
(`api_key`, `token`, `password`, etc.) before hashing or validation.

## Deterministic evidence

`bin/fm-evidence-run.sh` executes a command through a Python subprocess with a
fresh environment, writes stdout/stderr/exit code, builds a manifest, and
SHA-256 hashes the bundle. It refuses to run commands whose arguments contain
volatile provider tokens.

## Rollout embargo

During a cutover, `bin/fm-rollout-embargo.sh` can forbid resumption of parked
GLX initiatives while permitting the cutover primary and its support work. A
new generation is write-once; permits and forbids append to the active
generation.
