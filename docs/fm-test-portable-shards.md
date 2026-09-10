# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints must be measured on the same instrument the lanes run on, or they describe something other than the lane.
The lanes were previously packed from the 2026-08-20 concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md), which runs 24 candidates across four local workers.
That record answers whether the candidates are safe to run concurrently, not how long a serial CI lane takes, and by 2026-09-10 the parallel set had grown about 3.2x past it without anything noticing.
Balance hints now come from serial runs of the real lanes on `ubuntu-latest`.

The current hints are the slowest value each script reached across six CI runs on 2026-09-10: [34459949083](https://github.com/kunchenguid/firstmate/actions/runs/34459949083), [34460760299](https://github.com/kunchenguid/firstmate/actions/runs/34460760299), [34462530836](https://github.com/kunchenguid/firstmate/actions/runs/34462530836), [34462758357](https://github.com/kunchenguid/firstmate/actions/runs/34462758357), [34466966385](https://github.com/kunchenguid/firstmate/actions/runs/34466966385), and [34470382458](https://github.com/kunchenguid/firstmate/actions/runs/34470382458).
Shard 2 completed in all six, so its scripts come from the uploaded `fm-test-timing-portable-parallel-2` artifacts.
Shard 1 was cancelled at its 10-minute cap in five of the six, so its scripts come from the `FM_TEST_END duration_ms=` markers in each cancelled job's log, which record every script that finished before the cancellation, plus the one complete `fm-test-timing-portable-parallel-1` artifact from run 34462758357.
Taking the slowest of several runs rather than a single run keeps the balance honest on a slow runner.

`n` below is how many of the six runs measured that script; the two scripts at `n=1` are the tail of shard 1 that only the one complete run reached.

| max duration_ms | n | script |
|---:|---:|---|
| 296481 | 6 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 164262 | 4 | `tests/fm-lint.test.sh` |
| 111145 | 6 | `tests/fm-pr-merge.test.sh` |
| 92944 | 6 | `tests/fm-test-run.test.sh` |
| 31870 | 6 | `tests/fm-x-mode.test.sh` |
| 30898 | 6 | `tests/fm-arm-pretool-check.test.sh` |
| 22144 | 6 | `tests/fm-backend-herdr.test.sh` |
| 16964 | 6 | `tests/fm-cd-pretool-check.test.sh` |
| 11557 | 6 | `tests/fm-crew-state.test.sh` |
| 8624 | 3 | `tests/fm-pi-primary-types.test.sh` |
| 6936 | 6 | `tests/fm-herdr-lab.test.sh` |
| 6563 | 6 | `tests/fm-grok-harness.test.sh` |
| 4939 | 6 | `tests/fm-send-popup-settle.test.sh` |
| 4798 | 6 | `tests/fm-composer-lib.test.sh` |
| 3861 | 6 | `tests/fm-send-strict.test.sh` |
| 2747 | 3 | `tests/fm-review-diff.test.sh` |
| 2477 | 6 | `tests/fm-tmux-submit-busy.test.sh` |
| 2265 | 6 | `tests/fm-spawn-batch.test.sh` |
| 2120 | 6 | `tests/fm-composer-ghost.test.sh` |
| 2051 | 6 | `tests/fm-send-settle.test.sh` |
| 1625 | 1 | `tests/fm-brief.test.sh` |
| 901 | 6 | `tests/fm-ensure-agents-md.test.sh` |
| 297 | 6 | `tests/fm-supervision-instructions.test.sh` |
| 99 | 1 | `tests/fm-transition-lib.test.sh` |

Those maxima total 828568 ms, about 13 min 49 s of serial work across the 24 scripts.
Establish that total before designing a split: a lane cancelled at its cap has no total, only a lower bound, and a split derived from a truncated number describes something other than the lane.

A local run is not a substitute for these hints.
A 2026-09-10 macOS cross-check of the same scripts, on a developer machine also running other work, came in between 1.7x and 5.0x slower than the runner: `tests/fm-test-run.test.sh` at 157420 ms against 92944 ms, `tests/fm-x-mode.test.sh` at 67217 ms against 31870 ms, and `tests/fm-composer-ghost.test.sh` at 10521 ms against 2120 ms.
The ratio varies by script, so local timings do not merely scale the lane, they reorder it, and a packing derived from them would balance the wrong thing.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.

| Lane | Script count | Packed duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 414269 ms (~6.90 min) |
| `portable-parallel-2` | 13 | 414299 ms (~6.90 min) |
| imbalance | | 30 ms |

`bin/fm-test-run.sh` holds the hints in `portable_parallel_weight_hints` and the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the current numbers from `bin/fm-test-run.sh --check-coverage`, which prints `parallel_max_ms` and `parallel_imbalance_ms` derived from those lists, rather than trusting the table above.

`tests/fm-pi-primary-types.test.sh` must stay in whichever lane the CI workflow installs the Pi package into, currently `portable-parallel-1`.

Two facts bound any future rebalance of these lanes.
`tests/fm-captain-hold-lifecycle.test.sh` alone is 296481 ms, 36 percent of the whole set, so no two-lane split can run shorter than that single script.
Against the 10-minute CI cap, the worst lane at 6.90 min leaves about 1.45x of tripwire margin, where the sibling serial lane keeps roughly 2x, so further growth is a trunk decision about the cap or the lane count rather than something another rebalance absorbs.

Nothing refuses a stale parallel hint the way `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT` bounds the serial lane; `--check-coverage` reports `parallel_unhinted` but does not fail on it.
Refresh these hints from a green run's `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

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
The 145 current hints include the slowest measurements retained from the `fm-test-timing-portable-serial-*` artifacts of three green CI runs on 2026-09-01, [33558082172](https://github.com/kunchenguid/firstmate/actions/runs/33558082172), [33523597838](https://github.com/kunchenguid/firstmate/actions/runs/33523597838), and [33463326167](https://github.com/kunchenguid/firstmate/actions/runs/33463326167), the completed-script measurements from [run 34342484144](https://github.com/kunchenguid/firstmate/actions/runs/34342484144), plus the 5121 ms native-Windows focused runner measurement for `tests/fm-pi-windows-shell-invocation.test.sh` from 2026-09-06T21:02Z.
Those per-script maxima total 4312606 ms of conservative balance weight.
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default; the current 154-script lane has nine such scripts, bringing its assignment weight to 4555606 ms.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of5` | 30 | 911111 ms (~15.19 min) |
| `portable-serial-2of5` | 31 | 911128 ms (~15.19 min) |
| `portable-serial-3of5` | 32 | 911128 ms (~15.19 min) |
| `portable-serial-4of5` | 31 | 911128 ms (~15.19 min) |
| `portable-serial-5of5` | 30 | 911111 ms (~15.19 min) |
| imbalance | | 17 ms |

The current table is generated from the runner's retained maxima plus its default for the nine unhinted scripts.
Run 34342484144 observed a shard reach about 20 minutes of passing work, so the 30-minute job cap keeps meaningful hang-tripwire margin for job setup and runner-speed spread.

The single longest script, `tests/fm-watch-triage.test.sh` at 262626 ms, is the floor for any shard count.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

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
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

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
| portable serial 1-5 | job `timeout-minutes: 30` | Current runners can take about 20 minutes; the 30-minute cap remains a hang tripwire while leaving margin for job setup and runner-speed spread. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
