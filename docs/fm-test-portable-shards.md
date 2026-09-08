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
The 152 current hints are the slowest measurements retained from the `fm-test-timing-portable-serial-*` artifacts of four green CI runs on 2026-09-07 and 2026-09-08, [34180535832](https://github.com/kunchenguid/firstmate/actions/runs/34180535832), [34167501605](https://github.com/kunchenguid/firstmate/actions/runs/34167501605), [34167485767](https://github.com/kunchenguid/firstmate/actions/runs/34167485767), and [34156531229](https://github.com/kunchenguid/firstmate/actions/runs/34156531229), plus the 5121 ms native-Windows focused runner measurement for `tests/fm-pi-windows-shell-invocation.test.sh` from 2026-09-06T21:02Z.
Those per-script maxima total 4974498 ms of conservative balance weight and cover the whole 152-script lane, so no script currently runs on the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner: individual scripts varied by up to 3x between single runs in the 2026-09-08 measurement.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough drifted hints let one shard carry far more than another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical, and it has now happened twice.
By 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
The 2026-09-01 remedy refreshed the hints and moved to five shards, and the lane was cancelling again within a day: shard 4 of 5 ran 15.7 minutes against the same cap by 2026-09-02T06:38Z, and by 2026-09-08 the hints predicted 13.69 minutes for every shard while the shards actually ran 13.08 to 19.15 minutes.
Both occurrences were the same failure, so the guards below check hint accuracy and shard headroom rather than only hint presence.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a guard to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of6` | 23 | 829090 ms (~13.82 min) |
| `portable-serial-2of6` | 26 | 829094 ms (~13.82 min) |
| `portable-serial-3of6` | 26 | 829097 ms (~13.82 min) |
| `portable-serial-4of6` | 26 | 829079 ms (~13.82 min) |
| `portable-serial-5of6` | 25 | 829059 ms (~13.82 min) |
| `portable-serial-6of6` | 26 | 829079 ms (~13.82 min) |
| imbalance | | 38 ms |

The current table is generated from the runner's retained maxima, which now cover every script in the lane.
Those weights are deliberately conservative, so a healthy run comes in under them: regrouping the four source runs' real per-script durations under this six-shard partition puts the worst shard at 13.14 to 13.37 min, 66 to 67% of the 20-minute job cap, against 13.82 min of assignment weight.

The single longest script, `tests/fm-watch-triage.test.sh` at 515417 ms, is the floor for any shard count.
At 8.59 min it is 10.4% of the whole lane, so no shard count can bring a shard below it.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
bin/fm-test-run.sh --check-shard-balance /tmp/fm-serial/<run-id>/*/*.json
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Shard balance guard

`--check-coverage` catches a hint that is missing; it cannot catch a hint that is wrong.
A hint table can be fully populated and still predict a perfect split while one shard runs 40% over and reaches its cap, which is how the 2026-09-08 recurrence passed the coverage guard green.
`bin/fm-test-run.sh --check-shard-balance <serial-lane.json>...` closes that gap against the timing artifacts the serial lanes already upload on every run.
Each artifact names the lane it ran as and every script it ran, so a shard is checked against its own recorded work rather than against a re-derived assignment.

It checks two properties, because they fail for different reasons and call for different remedies:

- Accuracy: a shard whose measured duration exceeds its hinted weight by more than `PORTABLE_SERIAL_MAX_HINT_DRIFT_PERCENT` fails, naming the scripts whose hints drifted most.
  The remedy is a hint refresh.
- Headroom: a shard whose measured duration exceeds `PORTABLE_SERIAL_WARN_SHARD_BUDGET_PERCENT` of the job cap warns without failing the run, and one that exceeds `PORTABLE_SERIAL_MAX_SHARD_BUDGET_PERCENT` fails.
  The warning sits well below the failure on purpose: the guard has to speak before the badge goes red, and per-script noise on this lane reaches 3x, so a failure line just above the worst healthy shard would redden green suites until someone switched the guard off.

A shard over its budget is not by itself evidence that the lane needs another runner, so the headroom report states what it measured against the cap and then only the cause it could establish.
It divides the reported work evenly across the configured shard count: when even that does not fit, the lane has outgrown its shard count and the remedy is raising `PORTABLE_SERIAL_SHARDS` and the `ci.yml` matrix; when it does fit, the shard is packed heavy rather than the lane being too big, and the report names the scripts that ran over their hints.
A shard that trips the headroom bound while its own hints have also drifted is reported under both bounds, so the drifted scripts are named either way.
Both remain visible and distinguishable: the estimates being wrong and the lane being too big have different remedies.

`PORTABLE_SERIAL_JOB_TIMEOUT_MINUTES` records the cap the headroom share is taken against, and `.github/workflows/ci.yml` passes its own `tests-portable-serial` `timeout-minutes` back through `--job-timeout-minutes`, which is refused when the two disagree.
`tests/fm-test-run.test.sh` parses the workflow and refuses when that job's real `timeout-minutes` key, the value the aggregate step passes, and the cap the runner reports do not all agree, so the cap cannot move in one place only.
The `tests-timing-aggregate` job runs the check after building the aggregate summary.
A cancelled shard uploads no artifact, so the check reports how many shards it could read and leaves the rest unchecked rather than guessing.

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
| portable serial 1-6 | job `timeout-minutes: 20` | Each balanced shard carries about 13.82 minutes of conservative assignment weight and measures 13.1 to 13.4 minutes on a real run, leaving roughly 1.5x hang-tripwire margin for job setup and runner-speed spread. The shard balance guard checks that margin on every run. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
