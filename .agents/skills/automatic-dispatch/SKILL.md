---
name: automatic-dispatch
description: Use when routing an authorized crewmate or scout task through version 2 subscription dispatch.
metadata:
  internal: true
---

# automatic-dispatch

[`configuration`](../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns schema and account lanes; `quota-array-dispatch` owns quota; `harness-adapters` owns catalogs and spawning.

## Intake sequence

1. Confirm authority and delivery posture.
2. Classify it as `trivial`, `standard`, `decomposable`, `ambiguous`, or `high_risk`.
   Produce `taskClass`, bounded `workType`, `risk`, `independent`, `requestedWorkers`, `requiredReasoningClass`, `estimatedSeconds`, and only subtasks that can progress independently without conflicting writes.
   Every independent subtask gets a unique bounded `taskId`, a fresh route generation, its own exact normalized request with its own `workType`, and its own `fm-route.sh select` call.
3. Validate policy and every profile.
   On version 2 failure, emit one visible policy diagnostic, use configured static dispatch, and make no optimization state mutation.
   Do not call `fm-route.sh select`, `observe`, `reserve`, or the outcome ledger on this path.
   In simulation, report the static proposal and launch nothing; then stop this procedure.
4. Resolve native symbolic accounts with `fm-account-lane.sh` without inspecting credentials.
   A native profile whose symbolic account is absent from this home is ineligible; continue evaluating qualified Pi or other local profiles before static fallback.
5. Use each runtime's authoritative catalog for model support and provider family.
6. Let `quota-array-dispatch` interpret one `quota-axi` snapshot for all candidates.
7. Build the request with exactly the fields from step 2 plus `taskId`.
   Do not add subtask lists or acceptance criteria to this strict schema.
   Build candidates with exactly `profile`, `harness`, `model`, `provider`, `lane`, `account`, `fitTier`, `reasoningClass`, `catalogSupported`, `authState`, `spendPriority`, `runwaySeconds`, `activeLane`, `historySuccesses`, `historyAttempts`, and `costTier`.
8. Run `fm-route.sh select` and show its exact fit, capacity, load, uncertainty, and tie evidence.
   `maxWorkers` is only a concurrency ceiling; never reuse one selection for another subtask.
   Call `fm-route.sh select --request FILE --candidates FILE` for that subtask only.
9. With a valid policy in simulation mode, call `fm-route.sh observe` for the proposed route and launch nothing.
10. Process each ready slot transactionally as select -> reserve -> immediately spawn before routing the next ready slot; never bulk-reserve slots for later spawn.
    Reserve with `fm-route.sh reserve --task TASK --generation GENERATION --profile PROFILE --provider PROVIDER --lane LANE --account ACCOUNT --class CLASS --work-type WORK_TYPE --risk RISK --mode MODE`.
    Give `fm-spawn.sh` all nine route fields: `--route-generation`, `--route-profile`, `--route-provider`, `--route-lane`, `--route-account`, `--route-class`, `--route-work-type`, `--route-risk`, and `--route-mode`.
    On reserve or spawn failure, use the existing exact abort cleanup or release for that task and generation, then stop and re-evaluate every remaining unspawned slot.
    A high-risk reviewer is a distinct review subtask with its own `taskId`, generation, request, selection, and `workType=review`; the independent reviewer from a different provider than every implementer becomes ready only after reviewable implementation artifacts exist.
11. After re-evaluation, retry one proven transient once, fall back on unavailable quota, authentication, or models, and stop immediately on unsafe or uncertain writes.
12. Stop when criteria are covered or work is dependent, redundant, quota-bound, or host-bound.

The normalized routing files and ledger must never include prompts, source code, credentials, cookies, token values, proprietary payloads, or raw tool output.
