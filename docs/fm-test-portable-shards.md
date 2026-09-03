# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the concurrent proof archive recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The 2026-08-30 proof ran 25 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 257371 | `tests/fm-pr-merge.test.sh` |
| 405025 | `tests/fm-x-mode.test.sh` |
| 356616 | `tests/fm-test-run.test.sh` |
| 165241 | `tests/fm-slack-captain-channel.test.sh` |
| 69791 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 67143 | `tests/fm-spawn-batch.test.sh` |
| 62519 | `tests/fm-backend-herdr.test.sh` |
| 42102 | `tests/fm-tmux-submit-busy.test.sh` |
| 36760 | `tests/fm-arm-pretool-check.test.sh` |
| 36102 | `tests/fm-lint.test.sh` |
| 27791 | `tests/fm-crew-state.test.sh` |
| 23417 | `tests/fm-cd-pretool-check.test.sh` |
| 21747 | `tests/fm-send-strict.test.sh` |
| 13267 | `tests/fm-herdr-lab.test.sh` |
| 12618 | `tests/fm-grok-harness.test.sh` |
| 7777 | `tests/fm-send-popup-settle.test.sh` |
| 7197 | `tests/fm-composer-ghost.test.sh` |
| 5487 | `tests/fm-composer-lib.test.sh` |
| 4967 | `tests/fm-brief.test.sh` |
| 4409 | `tests/fm-send-settle.test.sh` |
| 4132 | `tests/fm-review-diff.test.sh` |
| 3633 | `tests/fm-pi-primary-types.test.sh` |
| 2842 | `tests/fm-transition-lib.test.sh` |
| 788 | `tests/fm-supervision-instructions.test.sh` |
| 770 | `tests/fm-ensure-agents-md.test.sh` |

## Parallel lanes

The lane membership partition is the proven-isolated set reported by `bin/fm-test-isolation-proof.sh --list`.
The 2026-08-30 archive refresh records the current candidate set after replacing the obsolete decision-hold lifecycle candidate with the canonical captain-hold lifecycle candidate.
`portable-parallel-1` is ordered by the current measured durations so its `--jobs 2` scheduler balances the two workers.

| Lane | Script count | Serial sum | Estimated `--jobs 2` wall |
|---|---:|---:|---:|
| `portable-parallel-1` | 12 | 1091581 ms | 546416 ms (~546.4 s) |
| `portable-parallel-2` | 13 | 547931 ms | 321922 ms (~321.9 s) |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.
Water 7 invokes `--jobs 2` only for `portable-parallel-1`; `portable-parallel-2` remains serial because its concurrency oracle was rejected.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Hosted CI and Water 7 fallback

`.github/workflows/ci.yml` runs `portable-parallel-1` with `--jobs 2`, `portable-parallel-2` serially, five serial shards, and the real-Herdr family as separate GitHub-hosted `ubuntu-latest` jobs.
Shard membership and count remain owned by `bin/fm-test-run.sh`, and CI refuses a matrix count that disagrees with that owner.
The superseded historical Water 7 oracle is retained in [verification/ci-portable-parallel-jobs.md](verification/ci-portable-parallel-jobs.md); current candidate-set evidence is in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
If primary CI fails, `.github/workflows/ci-water7-fallback.yml` runs `bin/fm-ci.sh` as one self-hosted Water 7 `Suite`; maintainers may also dispatch it manually.
That fallback discovers and executes the serial shards sequentially, and admits and validates its verdict through the shared-host load guard.
Static portability checks run on Linux, while CI also runs the documented stock-macOS Bash lane when the broad suite is enabled.

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints are the slowest measurement of each of the lane's 139 scripts across the `fm-test-timing-portable-serial-*` artifacts of three green CI runs on 2026-09-01, [33558082172](https://github.com/kunchenguid/firstmate/actions/runs/33558082172), [33523597838](https://github.com/kunchenguid/firstmate/actions/runs/33523597838), and [33463326167](https://github.com/kunchenguid/firstmate/actions/runs/33463326167).
Those per-script maxima total 3809887 ms of conservative balance weight.
Taking the slowest of several runs rather than a single run keeps the balance honest on a slow runner: individual scripts varied by up to 20% between those three runs.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of5` | 27 | 761980 ms (~12.70 min) |
| `portable-serial-2of5` | 27 | 761972 ms (~12.70 min) |
| `portable-serial-3of5` | 28 | 761968 ms (~12.70 min) |
| `portable-serial-4of5` | 28 | 761984 ms (~12.70 min) |
| `portable-serial-5of5` | 29 | 761983 ms (~12.70 min) |
| imbalance | | 16 ms |

Replaying that partition against each of the three source runs' real per-script durations puts the worst shard at 12.54 min, 63% of the 20-minute job cap.

The single longest script, `tests/fm-watch-triage.test.sh` at 262626 ms, is the floor for any shard count.

Refresh the hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

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
## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-5 | job `timeout-minutes: 20` | Each balanced shard is about 12.7 minutes of measured script time, leaving roughly 1.6x hang-tripwire margin for job setup and runner-speed spread. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
