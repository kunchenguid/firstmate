---
name: automatic-dispatch
description: Use when routing an authorized crewmate or scout task through version 2 subscription dispatch.
metadata:
  internal: true
---

# automatic-dispatch

1. Classify as `trivial`, `standard`, `decomposable`, `ambiguous`, or `high_risk`.
   Produce `taskClass`, bounded `workType`, `risk`, `independent`, `requestedWorkers`, `requiredReasoningClass`, `estimatedSeconds`, and only independent nonconflicting subtasks.
   Every independent subtask gets a unique bounded `taskId`, a fresh route generation, its own exact normalized request with its own `workType`, and its own `fm-route.sh select` call.
3. Validate policy and every profile.
   On version 2 failure, emit one visible policy diagnostic, use configured static dispatch, and make no optimization state mutation.
   Do not call `fm-route.sh select`, `observe`, `reserve`, or the outcome ledger on this path.
   With valid version 2 mode `off`, automatic-dispatch uses configured static dispatch and stops before account/candidate resolution, `select`, `observe`, `reserve`, or any routing ledger/state mutation.
4. Resolve native symbolic accounts with `fm-account-lane.sh` without inspecting credentials.
   A native profile whose symbolic account is absent from this home is ineligible; continue evaluating qualified Pi or other local profiles before static fallback.
5. Use each runtime's authoritative catalog.
6. `quota-array-dispatch` interprets one `quota-axi` snapshot for all candidates.
7. Build exactly `taskId` and the step 1 fields.
   Do not add subtask lists or acceptance criteria to this strict schema.
   Build candidates with exactly `profile`, `harness`, `model`, `provider`, `lane`, `account`, `fitTier`, `reasoningClass`, `catalogSupported`, `authState`, `spendPriority`, `runwaySeconds`, `activeLane`, `historySuccesses`, `historyAttempts`, and `costTier`.
8. Run `fm-route.sh select`.
   `maxWorkers` is only a concurrency ceiling; never reuse one selection for another subtask.
   Call `fm-route.sh select --request FILE --candidates FILE` for that subtask only.
9. With valid simulation mode, call `fm-route.sh observe` after selection, launch nothing, and stop before reserve/spawn.
10. Process each ready slot transactionally as select -> reserve -> immediately spawn before routing the next ready slot; never bulk-reserve slots for later spawn.
    Preserve the exact request file, candidates file, and captured decision.
    Reserve with `fm-route.sh reserve --task TASK --generation GENERATION --profile PROFILE --provider PROVIDER --lane LANE --account ACCOUNT --class CLASS --work-type WORK_TYPE --risk RISK --mode MODE --request REQUEST.json --candidates CANDIDATES.json --decision DECISION.json`.
    Reservation re-runs selection against authoritative load and the active version 2 policy under its state lock. Any stale decision or policy change means stop and re-evaluate; never edit selector evidence or substitute a profile/tuple.
    Pass the selected policy's exact `--harness HARNESS`, `--model MODEL`, and configured `--effort EFFORT`.
    Give `fm-spawn.sh` all nine route fields: `--route-generation`, `--route-profile`, `--route-provider`, `--route-lane`, `--route-account`, `--route-class`, `--route-work-type`, `--route-risk`, and `--route-mode`.
    On reserve or spawn failure, use the existing exact abort cleanup or release for that task and generation, then stop and re-evaluate every remaining unspawned slot.
    A high-risk reviewer is a distinct review subtask with its own `taskId`, generation, request, selection, and `workType=review`; the independent reviewer from a different provider than every implementer becomes ready only after reviewable implementation artifacts exist.
11. Retry one proven transient once; stop immediately on unsafe or uncertain writes.

Routing artifacts/ledger must never include prompts, source code, credentials, cookies, token values, proprietary payloads, or raw tool output.
