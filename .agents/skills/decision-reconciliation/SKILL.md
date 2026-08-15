---
name: decision-reconciliation
description: >-
  Agent-only policy for reconciling backlog captain holds against durable operating policies.
  Load before applying a captain-approved policy record to duplicate backlog questions, retiring inactive work, registering bounded implementation packages, or closing routine ship work after the verification gate.
user-invocable: false
metadata:
  internal: true
---

# Decision reconciliation

This skill is the single policy owner for reconciling queued backlog work against durable captain-approved operating policies.

## Problem this solves

Repeated captain questions, unclear completion authority, and missing durable decision-to-work links created a coordination backlog.
Each queued item must map to exactly one outcome: resolved by policy, a bounded implementation package, retired, or a genuine exception.

## Policy

Firstmate owns routine implementation choices, tests, evaluation, retries, documentation when behavior changes, policy-record maintenance, duplicate-decision cleanup, and exception summaries.
Routine work may close or merge only after relevant tests, review, required documentation, and the existing verification gate pass.

The captain retains product direction, privacy, money and new spending, security-sensitive changes, destructive or irreversible actions, and high-impact releases.
Those categories remain real captain questions even when a duplicate backlog hold exists.

## Reconciliation outcomes

Classify every queued item exactly once:

1. **Resolved by policy** - link the hold or task to a policy id in `docs/operating-policies.toml`, close the duplicate captain question with `bin/fm-decision-reconcile.sh resolve-hold`, and do not ask it again.
2. **Implementation package** - group related tasks that share policy and code surface into one bounded package in `docs/implementation-packages.toml` with one owner task.
3. **Retired** - archive inactive work, including all Job Tracker and career items, with `bin/fm-decision-reconcile.sh retire`.
4. **Genuine exception** - surface only a decision the policy record cannot answer; record it in the private task report with impact and recommendation.

Do not create or start implementation work for policy-resolved items.
Do not publish captain-private preferences, credentials, repository-specific security findings, or the source decision record in a community PR.

## Operating sequence

1. Read the complete approved policy record privately before changing backlog state.
2. Inventory every queued backlog item in the authoritative primary home.
3. Classify each item once and write the detailed mapping to the private task report only.
4. Apply durable links and duplicate-decision cleanup through `bin/fm-decision-reconcile.sh`.
5. Register or update bounded packages in `policies/implementation-packages.toml`.
6. Surface only genuine exceptions to the captain through Bearings Captain's Call.
7. For routine ship tasks that passed the verification gate, use `bin/fm-routine-complete.sh verify` before merge.

`policies/operating-policies.toml` owns community-safe policy ids and summaries.
`policies/implementation-packages.toml` owns bounded package ownership.
`docs/decision-reconciliation.md` records mechanism and regression evidence without restating this policy.
`bin/fm-decision-reconcile.sh --help` owns command syntax.
`bin/fm-routine-complete.sh --help` owns routine completion verification after the verification gate.

## Authority boundaries

| Topic | Firstmate routine authority | Captain escalation |
| --- | --- | --- |
| Tests, docs, retries within accepted intent | yes | no |
| Duplicate-decision cleanup when policy answers the question | yes | no |
| Privacy model or learner-data reuse | no | yes |
| New spending, paid providers, human recording | no | yes |
| Security-sensitive or billing-trust changes | no | yes |
| Destructive or irreversible actions | no | yes |
| Product direction and high-impact releases | no | yes |

Standing `yolo` never overrides the captain escalation rows above.
