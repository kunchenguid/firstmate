# Crosscheck overnight release report, 2026-08-26

## Outcome

The five-release train is implemented as stacked branches and remains unmerged.
The starting base is `ba0b8984da1b42dd38a0a03c185dfd09bdea81ac`.
Exact-head binding, credential isolation, Azure compartment identity, cleanup,
and fail-closed admission remain intact. No Azure image, network, or cloud policy
was changed.

| Release | Branch / PR | Outcome | Live checkpoint |
| --- | --- | --- | --- |
| R1 | `cc-r1` / #337 | Ready | PR #327 was admitted `BLOCKING`, cleanup complete |
| 2A | `cc-2a` / #339 | Ready, checkpoint parked | First run reached a semantic `CLEAR` but failed report rendering; the repair is covered offline and the retry stopped at shared allocation |
| 2B1 | `cc-2b1` / #340 | Ready | V1 exact head admitted `CLEAR`, identity-only, zero proof VMs, cleanup complete |
| 2B2 | `cc-2b2` / #341 | Ready, Azure checkpoint parked | Six real local Fireworks reviews were `CLEAR`; the V2 Azure run was interrupted after 31 minutes waiting for shared proof capacity after model completion |
| 2C | `cc-2c` / #343 | Ready, checkpoint parked | Offline and real-model prerequisites passed; no additional Azure run was launched into the same unresolved allocator contention |

PR #343 is the expected number at report creation time and should be corrected
if GitHub assigns a different number.

## Release evidence

### R1

- Commits: `d91f84fd`, `46992cd1`
- Task: `azure-nm-offload-fix-k4`
- Target: PR #327 at `80f1c54b5e07df0e0fbd5a0e1ae5a88931832c14`
- Durable state: `blocking`
- Finding: `cc-8f48584d092b`, `claimed-fixed`
- Azure evidence pairs: 1
- Model and staging cleanup: complete
- Wall time: 2,148.439 seconds
- Declared cost: `$0.3374772`

### Release 2A

- Commits: `d10ee260`, `0a0c2b37`
- Task: `cc-2a-v1-e616a585-20260826`
- First attempt: semantic `CLEAR` reached, then report rendering failed closed
- Wall time: 444.566 seconds
- Declared cost: `$0.0122704`
- Retry task: `cc-2a-v1b-e616a585-20260826`
- Retry: failed before model dispatch after bounded shared allocation wait
- Retry wall time: 4,477.463 seconds
- Retry declared cost: `$0`

### Release 2B1

- Commits: `f6f08fd`, `e0b3c0c6`
- Task: `cc-2b1-v1-e616a585-20260826b`
- Target: V1 PR #338 at `e616a585347e4713d1721bfe6ddec16c86d0c668`
- Durable state: `clear`
- Evidence mode: `identity-only-v1`, with zero proof compartments
- Model and staging cleanup: complete
- Official verifier returned the exact head
- Wall time: 380.856 seconds
- Declared cost: `$0.0094676`
- V1 was closed without merge

### Release 2B2

- Commits: `e5277382`, `d8e53aee`
- Six real local Fireworks GLM reviews against V1 all returned `CLEAR`
- Local wall times: 28.133, 17.973, 23.445, 24.843, 33.013, and 17.804 seconds
- Local declared costs: `$0.01402122`, `$0.00912002`, `$0.01424148`,
  `$0.01898644`, `$0.02161564`, and `$0.00941884`
- Azure task: `cc-2b2-v2-a65a81b9-20260826a`
- Target: V2 PR #342 at `a65a81b9`
- The model review completed, then the run waited more than 31 minutes for
  shared proof-compartment capacity. It was interrupted instead of live-debugged.
- The official wrapper unwound model, staging, and allocator cleanup. No durable
  run or admitted verdict exists, so V2 remains unreviewed by this checkpoint.

### Release 2C

- Parent-failing evidence: `d8e53aee` has no controller Ketch round, and the
  new two-pass runtime regression observes only one Pi launch on that parent.
- Controller Ketch is fixed to `/opt/homebrew/bin/ketch` v0.14.0 with fixed argv,
  isolated configuration, sanitized environment, bounded time/output, and no shell.
- Query privacy screening covers URLs, command options, tokens, secrets, both
  base and fork repository identities, private diff fragments, snapshot content,
  and snapshot paths.
- A provisional lookup pass has no verdict authority. A fresh final pass is
  digest-bound to the lookup results, cannot request another lookup, and retains
  combined spend and latency even when final identity validation fails.
- Correctably rejected terminal calls can recover inside one Pi launch; the
  accepted append-only event log remains authoritative.
- The paid Azure checkpoint is parked. The immediately preceding V2 run had
  already demonstrated unresolved shared proof-capacity contention, so another
  paid run was not started merely to reproduce that infrastructure wait.

## Validation

- Core Crosscheck suite: passed, about 239 seconds
- Azure Crosscheck suite: passed, 6.3 seconds
- Ledger compatibility suite: 8 passed, 0.199 seconds
- Python, Node, and shell syntax: passed
- `git diff --check`: passed
- Final adversarial review: no P0-P2 findings

The 2C regressions include command-boundary option rejection, base/fork privacy,
large and malformed content, unavailable Ketch, cache behavior, two-pass cost and
identity binding, second-lookup refusal, failed-follow-up telemetry, and both
correctable terminal-call recovery shapes.

## Spend

Ledger-attributable declared spend is `$0.44661884`:

- R1: `$0.3374772`
- 2A: `$0.0122704`
- 2B1: `$0.0094676`
- 2B2 local loop: `$0.08740364`

The interrupted 2B2 Azure attempt completed one model pass but wrote no durable
ledger, so its exact model and Azure infrastructure cost is unavailable. No 2C
paid attempt was launched. The observed work stayed far below the `$200` cap.

## Backup and disposable PRs

- Pre-run R1 ledger backup:
  `/Users/dongkeun/firstmate-home/data/azure-nm-offload-fix-k4/crosscheck-ledger.json.bak-overnight-20260826T024842Z`
- No other pre-existing live ledger was modified; later checkpoint task IDs were new.
- V1 PR #338: closed without merge
- V2 PR #342: closed without merge after the parked checkpoint

## Recommended merge order

1. `cc-r1` / PR #337
2. `cc-2a` / PR #339
3. `cc-2b1` / PR #340
4. `cc-2b2` / PR #341
5. `cc-2c` / PR #343
6. Re-review open Firstmate PRs once after the full train merges

Do not merge a child before its parent. Before each merge, rebase or retarget only
as needed to preserve the stack and rerun that PR's required checks.
