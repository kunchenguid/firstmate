---
name: automatic-dispatch
description: Use when routing an authorized crewmate or scout task through version 2 subscription dispatch.
metadata:
  internal: true
---

# automatic-dispatch

This skill owns classification, normalized router input, and launch sequencing.
`quota-array-dispatch` remains the sole owner of quota evidence interpretation; `harness-adapters` owns runtime catalogs and spawning mechanics.

## Intake sequence

1. Confirm the task's existing authority and repository delivery posture before routing.
2. Classify it as `trivial`, `standard`, `decomposable`, `ambiguous`, or `high_risk`.
   Produce `taskClass`, bounded `workType`, `risk`, `independent`, `requestedWorkers`, `requiredReasoningClass`, `estimatedSeconds`, and only subtasks that can progress independently without conflicting writes.
3. Validate the matched policy and resolve every profile.
   If version 2 validation fails, emit one visible policy diagnostic, hand control to configured static dispatch, and make no optimization state mutation.
   Do not call `fm-route.sh select`, `observe`, `reserve`, or the outcome ledger on this path.
   In simulation, report the static proposal and launch nothing; then stop this procedure.
4. Resolve each native profile's symbolic account with `fm-account-lane.sh` without inspecting credential contents.
   A native profile whose symbolic account is absent from this home is ineligible; continue evaluating qualified Pi or other local profiles before static fallback.
5. Use each runtime's authoritative catalog to establish model support and provider family.
6. Load `quota-array-dispatch` once to interpret one current `quota-axi` snapshot for all candidates.
7. Build the request with exactly the fields from step 2 plus `taskId`.
   Do not add subtask lists or acceptance criteria to this strict schema.
   Build candidates with exactly `profile`, `harness`, `model`, `provider`, `lane`, `account`, `fitTier`, `reasoningClass`, `catalogSupported`, `authState`, `spendPriority`, `runwaySeconds`, `activeLane`, `historySuccesses`, `historyAttempts`, and `costTier`.
8. Run `fm-route.sh select` and show its exact fit, capacity, load, uncertainty, and tie evidence.
9. With a valid policy in simulation mode, call `fm-route.sh observe` for the proposed route and launch nothing.
10. In canary or automatic mode, reserve every approved independent slot before calling `fm-spawn.sh` with its complete route tuple.
    High-risk work requires an independent reviewer from a different provider.
11. Retry one proven transient once, fall back on quota, authentication, or model unavailability, and stop immediately on unsafe or uncertain writes.
12. Stop spawning once acceptance criteria are covered or remaining work is dependent, redundant, quota-bound, or host-bound.

The normalized routing files and ledger must never include prompts, source code, credentials, cookies, token values, proprietary payloads, or raw tool output.
