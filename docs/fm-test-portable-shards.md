# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the concurrent proof archive recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The 2026-08-20 proof ran 25 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 44699 | `tests/fm-pr-merge.test.sh` |
| 41422 | `tests/fm-arm-pretool-check.test.sh` |
| 40136 | `tests/fm-x-mode.test.sh` |
| 37725 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 32074 | `tests/fm-backend-herdr.test.sh` |
| 29662 | `tests/fm-test-run.test.sh` |
| 24513 | `tests/fm-slack-captain-channel.test.sh` |
| 23769 | `tests/fm-cd-pretool-check.test.sh` |
| 16205 | `tests/fm-crew-state.test.sh` |
| 12196 | `tests/fm-herdr-lab.test.sh` |
| 8576 | `tests/fm-grok-harness.test.sh` |
| 8386 | `tests/fm-spawn-batch.test.sh` |
| 5428 | `tests/fm-send-popup-settle.test.sh` |
| 4438 | `tests/fm-review-diff.test.sh` |
| 3409 | `tests/fm-send-settle.test.sh` |
| 3321 | `tests/fm-send-strict.test.sh` |
| 3239 | `tests/fm-brief.test.sh` |
| 2586 | `tests/fm-composer-ghost.test.sh` |
| 2086 | `tests/fm-tmux-submit-busy.test.sh` |
| 1792 | `tests/fm-lint.test.sh` |
| 442 | `tests/fm-supervision-instructions.test.sh` |
| 312 | `tests/fm-ensure-agents-md.test.sh` |
| 193 | `tests/fm-transition-lib.test.sh` |
| 103 | `tests/fm-composer-lib.test.sh` |
| 22 | `tests/fm-pi-primary-types.test.sh` |

## Parallel lanes

The lane membership partition is the 2026-07-29 longest-processing-time assignment over the 24 candidates proven at that time, plus `tests/fm-slack-captain-channel.test.sh`, which was added to the proven set and inserted into `portable-parallel-1` afterwards without a rebalance.
The 2026-08-20 archive refresh extends concurrent-proof coverage to that member and restates every per-script duration in the table above; it changes no lane membership.
The estimates below therefore apply the current durations to that fixed partition; they are not a fresh longest-processing-time balance, and neither the partition nor the listed execution order is sorted by the current durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 12 | 176651 ms (~176.7 s) |
| `portable-parallel-2` | 13 | 170083 ms (~170.1 s) |
| imbalance | | 6568 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Hosted CI and Water 7 fallback

`.github/workflows/ci.yml` runs the two portable parallel lanes, four serial shards, and real-Herdr family as separate GitHub-hosted `ubuntu-latest` jobs.
Shard membership and count remain owned by `bin/fm-test-run.sh`, and CI refuses a matrix count that disagrees with that owner.
See [verification/ci-portable-parallel-jobs.md](verification/ci-portable-parallel-jobs.md) for the measured oracle evidence.
If primary CI fails, `.github/workflows/ci-water7-fallback.yml` runs `bin/fm-ci.sh` as one self-hosted Water 7 `Suite`; maintainers may also dispatch it manually.
That fallback discovers and executes the serial shards sequentially, and admits and validates its verdict through the shared-host load guard.
Static portability checks run on Linux, while [CONTRIBUTING.md](../CONTRIBUTING.md) records the required local stock-macOS Bash lane rather than adding a hosted macOS dependency.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

`bin/fm-test-run.sh --json <path>` writes one lane's runner-generated timing JSON, and `bin/fm-test-run.sh --aggregate-json out.json <lane>.json ...` merges lanes for critical-path review.
Primary CI uploads per-shard timing JSON and an aggregate artifact.
The Water 7 fallback uses the same flag for job-summary observability: when `GITHUB_STEP_SUMMARY` is set, `bin/fm-ci.sh` collects one timing JSON per executed lane in a temporary directory under `RUNNER_TEMP` and appends a compact lane report to the job summary.
`bin/fm-test-run.sh --aggregate-json` remains the single owner of cross-lane merging and slowest-test ranking, while `bin/fm-ci.sh` only renders those aggregate fields for the job summary.
Both collection and publication are non-blocking: `bin/fm-test-run.sh` reports an unwritable timing artifact without changing the suite exit status it already decided, and `bin/fm-ci.sh` reports a publish failure without changing the policy verdict.
Publication is success-only: a failing lane still fails the policy at that lane, so a job summary carries a timing report only when every lane passed.
CI stops there: merging those lanes is not a landing gate, and no timing JSON outlives the job.
`bin/fm-ci.sh` owns the exact summary contents and GitHub presentation only.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.
