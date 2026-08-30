# Water 7 portable-parallel `--jobs 2` verification

Audience: maintainer verification.

The active candidate-set evidence is [fm-test-isolation-proof.md](../fm-test-isolation-proof.md), and the current lane composition and timing inputs are [fm-test-portable-shards.md](../fm-test-portable-shards.md).
Task chronology and delivery evidence beyond the measured runs stay in the PR.
The Water 7 timing-summary regression behavior is covered by `tests/fm-ci-water7.test.sh`.

## 2026-08-30 current-candidate equivalence refresh

The lane-1 serial-versus-parallel oracle was rerun at commit `5a3a56f2` after replacing the obsolete decision-hold candidate with `tests/fm-captain-hold-lifecycle.test.sh` and rebalancing the lane order.
Both commands selected the same 12 scripts, and every script produced the same `{exit=0, gate_skip=false}` result in serial and under `--jobs 2`.
The serial run completed in 291596 ms with load averages `{ 2.56 3.64 3.45 }` before and `{ 3.97 3.25 3.26 }` after.
The parallel run completed in 163757 ms with load averages `{ 3.89 3.24 3.26 }` before and `{ 6.83 5.13 4.05 }` after.
This current exact-candidate result supersedes the historical `f2fc52e` oracle below for CI admission; the older repeated-run record remains as provenance for the original policy.

```sh
bin/fm-test-run.sh --lane portable-parallel-1 --json /tmp/portable-parallel-1-serial.json
bin/fm-test-run.sh --lane portable-parallel-1 --jobs 2 --json /tmp/portable-parallel-1-jobs2.json
```

The compared result set is:

```text
tests/fm-brief.test.sh exit=0 gate_skip=false
tests/fm-captain-hold-lifecycle.test.sh exit=0 gate_skip=false
tests/fm-cd-pretool-check.test.sh exit=0 gate_skip=false
tests/fm-composer-ghost.test.sh exit=0 gate_skip=false
tests/fm-grok-harness.test.sh exit=0 gate_skip=false
tests/fm-lint.test.sh exit=0 gate_skip=false
tests/fm-pi-primary-types.test.sh exit=0 gate_skip=false
tests/fm-review-diff.test.sh exit=0 gate_skip=false
tests/fm-slack-captain-channel.test.sh exit=0 gate_skip=false
tests/fm-test-run.test.sh exit=0 gate_skip=false
tests/fm-transition-lib.test.sh exit=0 gate_skip=false
tests/fm-x-mode.test.sh exit=0 gate_skip=false
```

## Historical acceptance oracle

Verified 2026-08-20 on GNU bash 5.x under Linux.
Every five-serial/five-parallel measurement in this record was taken at the single commit `f2fc52e`.
On the evidence branch, later changes left both measured lane lists byte-identical: `4b0940e` rolled `portable-parallel-2` back to serial, and a later review commit raised the host `CPUQuotaPerSecUSec` floor to 2 so the admission guard covered the concurrency in this policy.
The current fallback still runs the accepted lane-1 command and keeps lane 2 serial; the primary hosted shard topology is owned by `.github/workflows/ci.yml` and does not depend on this host-specific measurement.

Oracle rules:

- Five serial (`--lane`, default `N=1`) and five parallel (`--jobs 2 --lane`) runs per candidate lane on one exact commit.
- Compare every `FM_TEST_END` as `{script,exit,gate_skip}`; matching counts alone is insufficient.
- Require unchanged coverage (`bin/fm-test-run.sh --check-coverage`).

Coverage at `f2fc52e`, unchanged by every later commit on this branch:

```
FM_TEST_COVERAGE ok total=143 parallel=25 serial=106 serial_shards=4 herdr=12
```

### Historical `portable-parallel-1` with `N=2` - accepted

All nine serial-vs-parallel comparisons matched the `serial-portable-parallel-1-1` reference set.

Wall-clock seconds per run (`elapsed_s`, all `rc=0`):

| mode | run 1 | run 2 | run 3 | run 4 | run 5 | mean |
|---|---:|---:|---:|---:|---:|---:|
| serial | 168 | 165 | 162 | 160 | 158 | 162.6 |
| parallel (`--jobs 2`) | 80 | 80 | 86 | 82 | 82 | 82.0 |

Reference `FM_TEST_END` set (12 scripts):

```
tests/fm-brief.test.sh exit=0 gate_skip=false
tests/fm-cd-pretool-check.test.sh exit=0 gate_skip=false
tests/fm-composer-ghost.test.sh exit=0 gate_skip=false
tests/fm-decision-hold-lifecycle.test.sh exit=0 gate_skip=false
tests/fm-grok-harness.test.sh exit=0 gate_skip=false
tests/fm-lint.test.sh exit=0 gate_skip=false
tests/fm-pi-primary-types.test.sh exit=0 gate_skip=true
tests/fm-review-diff.test.sh exit=0 gate_skip=false
tests/fm-slack-captain-channel.test.sh exit=0 gate_skip=false
tests/fm-test-run.test.sh exit=0 gate_skip=false
tests/fm-transition-lib.test.sh exit=0 gate_skip=false
tests/fm-x-mode.test.sh exit=0 gate_skip=false
```

Mean wall time dropped from 162.6 s to 82.0 s (~50% of serial).

### Historical `portable-parallel-2` with `N=2` - rejected

Initial oracle: four of five parallel runs matched serial; run 5 differed only on `tests/fm-backend-herdr.test.sh` (`exit=1` vs `exit=0`) with:

```
error: herdr server for session 'fmtest' did not report running within 10s
```

Follow-up reruns of `--jobs 2 --lane portable-parallel-2` on the same host: four of five matched; one run failed with the same `fm-backend-herdr.test.sh` exit mismatch.

Wall-clock seconds from the initial oracle (`elapsed_s`):

| mode | run 1 | run 2 | run 3 | run 4 | run 5 | mean (passing only) |
|---|---:|---:|---:|---:|---:|---:|
| serial | 149 | 150 | 177 | 177 | 171 | 164.8 |
| parallel (`--jobs 2`) | 101 | 106 | 115 | 115 | 215 (`rc=1`) | 109.3 |

At that historical point, `N=2` was not wired into CI for this lane until a new proof showed identical `{script,exit,gate_skip}` sets under load.

## Historical fallback policy

`bin/fm-ci.sh`, invoked by `.github/workflows/ci-water7-fallback.yml` after primary CI failure or by manual dispatch:

```sh
bin/fm-test-run.sh --jobs 2 --lane portable-parallel-1
bin/fm-test-run.sh --lane portable-parallel-2
```

The current Water 7 policy still invokes `portable-parallel-1` with `--jobs 2`; the 2026-08-30 refresh above re-proves that command after the candidate replacement and reorder.

Measured opportunity on this host at acceptance time:

- Baseline combined serial mean for both lanes: 162.6 + 164.8 = 327.4 s.
- After change (lane 1 parallel, lane 2 serial): 82.0 + 164.8 = 246.8 s.
- Observed saving: ~80.6 s (~25% of the two-lane serial total), smaller than the 2026-08-19 Water 7 baseline estimate because only one lane parallelizes and this host's serial timings differ from that sample.

## Contract test RED before fix

After changing `bin/fm-ci.sh` but before updating `tests/fm-ci-water7.test.sh`:

```
not ok - Water 7 command policy changed its complete serial order: lint
test-run --check-coverage
test-run --jobs 2 --lane portable-parallel-1
test-run --jobs 2 --lane portable-parallel-2
test-run --lane portable-serial
test-run --family real-herdr-gated --fail-on-gate-skip herdr not found
```

## Reproduce

From the repository root:

```sh
# Lane 1 oracle spot-check (one serial, one parallel)
bin/fm-test-run.sh --lane portable-parallel-1 2>&1 |
  grep '^FM_TEST_END ' | awk '{print $3, $4, $6}' | sort
bin/fm-test-run.sh --jobs 2 --lane portable-parallel-1 2>&1 |
  grep '^FM_TEST_END ' | awk '{print $3, $4, $6}' | sort

# Policy contract
tests/fm-ci-water7.test.sh
```
