# Behavior test sharding

`bin/fm-behavior-shards.sh` is the single owner of behavior-test shard planning, execution manifests, timing refresh, and completeness verification.

## Baseline

The 2026-07-31 `main` behavior job ran all 80 scripts serially from 16:41:30 UTC to 17:38:53 UTC, or 57 minutes 23 seconds.

The source run is [GitHub Actions run 30648119449](https://github.com/ruby-dlee/firstmate/actions/runs/30648119449).

`tests/behavior-test-durations.tsv` records the per-script measurements derived from that run.

The current inventory contains 87 behavior-test scripts, including the runner contract test and every test added on `main` since the baseline run.

## Assignment

The planner uses deterministic longest-processing-time assignment.

It sorts by descending recorded duration, uses the test path as the stable secondary key, assigns the next test to the currently lightest shard, and breaks load ties by the lowest shard number.

The eight-shard checked-in plan has these estimated serial loads.

| Shard | Tests | Estimated load |
|---:|---:|---:|
| 1 | 1 | 475500 ms (7m56s) |
| 2 | 11 | 436053 ms (7m16s) |
| 3 | 15 | 436051 ms (7m16s) |
| 4 | 13 | 436048 ms (7m16s) |
| 5 | 12 | 436056 ms (7m16s) |
| 6 | 10 | 436296 ms (7m16s) |
| 7 | 10 | 436222 ms (7m16s) |
| 8 | 15 | 436053 ms (7m16s) |

The account-routing and report-stack suites keep their original test functions and assertions in shared suite files, while two runner wrappers partition each call list deterministically between isolated runners.

The report-stack partition keeps the persistent-retention-owner setup in the same wrapper as its generation-interruption dependent.

The largest remaining indivisible test file, `tests/fm-checkout-refresh.test.sh`, sets the 7-minute-56-second floor.

## Measured GitHub Actions result

[GitHub Actions run 30681093133](https://github.com/ruby-dlee/firstmate/actions/runs/30681093133) ran all eight shards and the executed-union guard from commit `4dcafc2cbc0d81c993e2314a6ad83e4aa1d9e008`.

The behavior check took 9 minutes 57 seconds from workflow creation at 02:59:39 UTC through final guard completion at 03:09:36 UTC.

The slowest matrix job was shard 1 at 9 minutes 25 seconds, and its behavior step took 9 minutes 13 seconds.

The serial baseline was 57 minutes 23 seconds, so the measured behavior check wall-clock fell by 47 minutes 26 seconds while retaining every test file and the final completeness proof.

| Shard | Job wall-clock | Behavior step | Result |
|---:|---:|---:|---:|
| 1 | 9m25s | 9m13s | pass |
| 2 | 8m28s | 8m19s | pass |
| 3 | 8m32s | 8m20s | pass |
| 4 | 6m59s | 6m48s | pass |
| 5 | 6m10s | 6m03s | pass |
| 6 | 6m18s | 6m11s | pass |
| 7 | 5m51s | 5m40s | pass |
| 8 | 8m43s | 8m31s | pass |

The same run measured the split wrappers at 423936 ms for account-routing A, 335548 ms for account-routing B, 261383 ms for report-stack A, and 243164 ms for report-stack B.

Those values replaced the provisional half-suite estimates in `tests/behavior-test-durations.tsv` and produced the assignment measured in that run.

The checked-in plan above also reflects the later teardown-suite split and tests added on `main`.

## Coverage guard

`bin/fm-behavior-shards.sh --check 8` fails when the duration inventory has a missing path, duplicate path, malformed duration, or any difference from the complete `tests/*.test.sh` inventory.

Every matrix runner writes an executed manifest while continuing through all assigned scripts and preserving each exit code.

The final `Behavior tests` job downloads all eight manifests and runs `bin/fm-behavior-shards.sh --verify 8 <manifest-dir>`.

Verification fails for a missing shard, missing test, duplicate test, wrong shard assignment, malformed row, or recorded test failure.

Shard artifacts are replaceable across workflow attempts, so rerunning failed jobs refreshes the failed shard while retaining successful shard evidence from the same workflow run.

The historical required-check name stays intact on this final union guard.

## Isolation and failure output

GitHub Actions gives every matrix leg a separate virtual machine, so shards do not share processes, ports, locks, paths, or terminal servers.

The workflow also assigns each shard private mode-0700 `TMPDIR` and `TMUX_TMPDIR` roots under that runner's `RUNNER_TEMP`.

Scripts remain serial within a shard, so no existing test needed weaker assertions, a mock conversion, a skip, a retry, or an added sleep.

Each matrix job is named `Behavior tests (shard N/8)`, and the runner emits explicit begin and end markers containing the test path and exit code.

The 15-minute per-shard timeout leaves bounded margin above the 9m25s measured slowest job while replacing the prior 90-minute blanket.

## Teardown child-endpoint investigation

GitHub Actions run 30649486198 failed at 17:52:54 UTC after `test_forced_secondmate_child_uses_child_home_for_endpoint_verification` correctly retained the Agent Fleet lease, child metadata, and child worktree but its final message assertion expected the endpoint state to be `unknown`.

The Zellij fixture returns a live session, pane, and tab from the child firstmate home, so endpoint discovery deterministically classifies it as `present` before destructive cleanup and emits `managed endpoint ... is still alive`.

The failure was therefore an assertion-ordering mismatch introduced when the fixture became capable of proving presence, not a delayed endpoint shutdown.

Commit `d7db2dcb010cc48f4ca6d34b4386d934e6c9cdde` fixes the assertion to match the proven state while retaining the refusal and all three containment checks.

GitHub Actions run 30657355610 executed the corrected sequence at 19:51:41 UTC and passed the full behavior job without a retry or added sleep.

## Refreshing timings

Run the complete suite serially in the target environment and atomically replace the duration data only if every test passes.

```sh
bin/fm-behavior-shards.sh --record tests/behavior-test-durations.tsv
bin/fm-behavior-shards.sh --check 8
```

Review the new `--check` load summary before committing refreshed timings.
