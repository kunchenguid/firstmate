# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The 157 current hints are the slowest measured `duration_ms` per script across the `fm-test-timing-portable-serial-*` artifacts of four green CI runs on 2026-09-10, [34413640474](https://github.com/kunchenguid/firstmate/actions/runs/34413640474), [34413651260](https://github.com/kunchenguid/firstmate/actions/runs/34413651260), [34413670094](https://github.com/kunchenguid/firstmate/actions/runs/34413670094), and [34439204619](https://github.com/kunchenguid/firstmate/actions/runs/34439204619).
Those per-script maxima total 5434244 ms of conservative balance weight and cover the whole 157-script lane, so no script currently runs on the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because drifted hints let one shard carry far more than another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical, and it has now happened three times.
By 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
The 2026-09-01 remedy refreshed the hints and moved to five shards, and the lane was cancelled again on 2026-09-08.
The remedy after that raised the cap from 20 to 30 minutes and refreshed the hints again, and on 2026-09-10 `Behavior portable serial 1` was still [cancelled at 30 min 15 s](https://github.com/kunchenguid/firstmate/actions/runs/34439141091/job/102750305543) with no hang: the shard was passing tests three seconds before the cancellation and simply ran out of budget.
Refreshing the hints repairs the balance but does not keep it repaired, which is why the shard balance guard below measures how close each shard actually runs to its cap rather than only whether its hints exist.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a guard to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of5` | 30 | 1086864 ms (~18.11 min) |
| `portable-serial-2of5` | 31 | 1086841 ms (~18.11 min) |
| `portable-serial-3of5` | 32 | 1086851 ms (~18.11 min) |
| `portable-serial-4of5` | 31 | 1086833 ms (~18.11 min) |
| `portable-serial-5of5` | 33 | 1086855 ms (~18.11 min) |
| imbalance | | 31 ms |

The current table is generated from the runner's retained maxima, which now cover every script in the lane.
Those weights are deliberately conservative, so a healthy run comes in under them.
The table was validated against a held-out run rather than fitted to the runs that produced it: rebuilding the hints from the four runs above and scoring that partition against [run 34447627189](https://github.com/kunchenguid/firstmate/actions/runs/34447627189), which contributed nothing to the table, puts its worst shard at 16.99 min against 18.11 min of assignment weight, with the five shards spanning 14.47 to 16.99 min.
The same held-out run under the previous hints spanned 13.24 to 21.93 min.

The single longest script, `tests/fm-watch-triage.test.sh` at 592748 ms, is the floor for any shard count.
At 9.88 min it is 10.9% of the whole lane, so no shard count can bring a shard below it.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
bin/fm-test-run.sh --check-shard-balance /tmp/fm-serial/<run-id>/*/*.json
```

Run the balance check separately for each run.
Refreshing hints changes the diagnosis of existing artifacts, not their recorded shard wall times.
A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, limiting reliance on the default weight.

## Shard balance guard

`--check-coverage` catches a hint that is missing; it cannot catch a hint that is wrong.
A hint table can be fully populated, predict a perfectly even split, and still leave one shard running to its cap while another idles, which is how the 2026-09-10 cancellation happened with the coverage guard green.
`bin/fm-test-run.sh --check-shard-balance <serial-lane.json>...` closes that gap against the timing artifacts the serial lanes already upload on every run.
Each artifact names the lane it ran as and every script it ran, so a shard is checked against its own recorded work rather than against a re-derived assignment.
The command expects numbered portable serial artifacts from one run.
Malformed or foreign timing artifacts raise unhandled errors rather than being skipped; neither the CI glob nor the invocation above supplies them.

It checks one property, the one actually being protected: how close a shard runs to the cap that would cancel it.
A shard whose recorded wall time exceeds `PORTABLE_SERIAL_MAX_SHARD_BUDGET_PERCENT` of the job cap fails; a shard at or below it passes.
The duration is the shard's own recorded wall time (`summary.duration_ms` in its artifact) rather than the sum of its scripts.

### Where the threshold comes from

The bound is 72% of the 30-minute `tests-portable-serial` cap, which is **21.6 minutes**.

It is derived from this lane's own measured run-to-run variance rather than chosen as a round number.
Across five green runs on 2026-09-10, shard 1 ran a mean of 21.75 min; on [run 34439141091](https://github.com/kunchenguid/firstmate/actions/runs/34439141091) the same shard reached 29.95 min and was cancelled, an excursion of **1.377x its own mean** driven by `tests/fm-watch-triage.test.sh` taking 19.86 min against a 9.0 min typical.
A shard sitting at X% of the cap therefore reaches the cap on an excursion of that size once X is at or above 72.6%.
The bound sits just below that: **21.6 minutes is the last point from which the worst excursion this lane has actually produced still finishes inside the 30-minute cap.**

That direction matters more than the exact figure.
A bound of 78% or higher fires on none of the 29 green shard measurements taken across those runs, including the runs immediately before the cancellation, so it could not have warned about anything.
A guard that cannot go red is worse than no guard, because it reassures.

The margin the bound leaves, in minutes:

| | minutes | share of the 30-minute cap |
|---|---:|---:|
| worst shard on the held-out run, current hints | 16.99 | 56.6% |
| guard fails above | 21.60 | 72% |
| job is cancelled at | 30.00 | 100% |

That leaves **4.61 minutes of growth** between a healthy lane and the guard's failure threshold, and a further 8.4 minutes between that threshold and a cancellation.
The numerator is the suite's wall clock while `timeout-minutes` bounds the whole job, so the share understates the job by whatever the surrounding steps cost.
That bias is measured, not assumed: across the 30 `tests-portable-serial` jobs of those runs, non-suite time ranged from 15 to 35 seconds, at most 1.9% of the cap, which does not consume the margin above.
Re-derive these numbers from fresh artifacts if the job gains or loses steps, or if the lane's variance changes.

### What it reports

The failure names the scripts furthest over their hints, so it says what to re-measure rather than only that a shard is slow.
The hint table feeds that list and nothing else here: it does not decide pass or fail, and the coverage guard's `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT` still owns hints that are missing.

The `tests-portable-serial` job's `timeout-minutes` in `.github/workflows/ci.yml` owns the job cap; `PORTABLE_SERIAL_JOB_TIMEOUT_MINUTES` records that cap for the guard.
`tests/fm-test-run.test.sh` parses the `tests-portable-serial` job's real `timeout-minutes` out of `.github/workflows/ci.yml` and compares it against the cap the guard reports, so the cap cannot move in one place only.
The `tests-timing-aggregate` job runs the check after building the aggregate summary.
A cancelled shard uploads no artifact, so the check reports how many of the shards its artifacts declare could actually be read and leaves the rest unchecked rather than guessing.
When no serial artifacts are available, CI warns and leaves shard balance unchecked.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-5 | job `timeout-minutes: 30` | See the [shard balance guard](#shard-balance-guard) for the measured margin and failure threshold. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
