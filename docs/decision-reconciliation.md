# Decision reconciliation mechanism

The normative policy is owned by `.agents/skills/decision-reconciliation/SKILL.md` and is not restated here.
This document records the deterministic mechanism, registries, and privacy-safe regression evidence.

## Coordination problem

Repeated captain questions, unclear completion authority, and missing durable decision-to-work links let duplicate backlog holds outlive the captain's approved answers.
The reconciliation layer closes that gap with community-safe policy ids, bounded implementation packages, and a routine completion verifier after the existing verification gate.

## Mechanism

`policies/operating-policies.toml` is the single owner of community-safe policy ids and summaries.
`policies/implementation-packages.toml` is the single owner of bounded package ownership.
`bin/fm-decision-reconcile.sh` applies policy links, resolves duplicate captain holds through the existing `bin/fm-decision-hold.sh decline` path, and retires inactive work.
`bin/fm-routine-complete.sh` verifies that a ship task's current-code-matched run step is done, its PR is recorded, and it has no open keyed status decisions before calling `bin/fm-pr-merge.sh`.

Policy resolution never substitutes for captain escalation categories named in the policy registry.
Security, spending, privacy, destructive, irreversible, product-direction, and high-impact-release boundaries remain captain authority.

## Verification record

Verification date: 2026-08-15.

```text
$ bash tests/fm-decision-reconcile.test.sh
$ bash tests/fm-routine-complete.test.sh
```

The focused regressions use only synthetic task identities and policy ids.
