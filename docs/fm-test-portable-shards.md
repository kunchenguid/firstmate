# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The retained hints are the slowest completed value each script reached across six CI runs on 2026-09-10: [34459949083](https://github.com/kunchenguid/firstmate/actions/runs/34459949083), [34460760299](https://github.com/kunchenguid/firstmate/actions/runs/34460760299), [34462530836](https://github.com/kunchenguid/firstmate/actions/runs/34462530836), [34462758357](https://github.com/kunchenguid/firstmate/actions/runs/34462758357), [34466966385](https://github.com/kunchenguid/firstmate/actions/runs/34466966385), and [34470382458](https://github.com/kunchenguid/firstmate/actions/runs/34470382458).
Shard 2 completed in all six, so its scripts come from the uploaded `fm-test-timing-portable-parallel-2` artifacts.
Shard 1 was cancelled at its job cap in five of the six, so its scripts come from the `FM_TEST_END duration_ms=` markers in each cancelled job's log, which record every script that finished before the cancellation, plus the one complete `fm-test-timing-portable-parallel-1` artifact from run 34462758357.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

The measurements cover all 24 candidates, with six samples per script except:

| Samples | Scripts |
|---:|---|
| 4 | `tests/fm-lint.test.sh` |
| 3 | `tests/fm-pi-primary-types.test.sh`, `tests/fm-review-diff.test.sh` |
| 1 | `tests/fm-brief.test.sh`, `tests/fm-transition-lib.test.sh` |

The two scripts with one sample are the tail of shard 1 that only the complete run reached.
Collect completed per-script measurements for every member before calculating a split.
A cancelled lane's elapsed duration is only a lower bound; its unfinished scripts have no completed duration for that invocation.
The complete historical run supplies tail-script hints, not a completion time for any later cancelled invocation or for the rebalanced jobs.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

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
The serial hints were refreshed from successful per-script records in the `fm-test-timing-portable-serial-*` artifacts of the complete green [run 35279383618](https://github.com/kunchenguid/firstmate/actions/runs/35279383618) and the available completed shards of [run 35282466441](https://github.com/kunchenguid/firstmate/actions/runs/35282466441) on 2026-09-17.
Together these cover all 176 serial scripts at refresh time; retain the slower successful sample where both exist.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
An unfinished or failed invocation is not a healthy duration sample.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Nine serial runners pack the refreshed measurements into a longest modeled script sum of 697969 ms (11m38s), with other shards near 10m36s.
The longest script, `tests/fm-watch-triage.test.sh`, legitimately occupies one whole shard and is the indivisible floor for this layout.
This is a packing estimate, not measured new-workflow execution or an end-to-end latency guarantee.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
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

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns two canonical CI partitions, each running the same full source-aware ShellCheck analysis with two bounded workers, pinned versions, workflow validation, and backend-purity checks.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots and unchanged analysis flags.
The workflow uploads each partition's quiet telemetry to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, reduced checks, or paid runner provisioning is part of this layout.

The performance objective is a complete green run under fifteen minutes including start delay: roughly twelve minutes of longest-path execution, at most two minutes of runner delay, and less than one minute of other overhead.
The candidate uses fourteen long-lived Linux jobs (nine serial, two parallel, Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound is wedged, not slow, so change the policy here rather than treating the bound as a way to fit a slower lane.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | Rust context continuity, lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
