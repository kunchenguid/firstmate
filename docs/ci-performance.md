# CI performance evidence

This file records reproducible timing evidence for the canonical lint and portable behavior gates.
The policy and exact commands remain owned by `bin/fm-lint.sh`, `bin/fm-test-run.sh`, and `tests/behavior-shards.txt`.

## Baseline, 2026-07-22

The upstream GitHub Actions baseline was successful run `29865056632` at commit `c58cb0f` on `ubuntu-latest`.
The behavior job took about 782 seconds end to end, with the serial `tests/*.test.sh` loop consuming about 775 seconds.
The lint job took about 381 seconds in its monolithic ShellCheck invocation.
These timestamps and per-suite estimates were collected in the completed safe queue-throughput audit at `data/fm-optimization-scout/report.md` in the operating Firstmate home.

The implementation worktree baseline was commit `b843c66`, Linux x86_64, 8 reported CPUs, ShellCheck 0.11.0, and the exact commands below.

```sh
RUNNER_TEMP="$PWD/.tasktmp/runner" bin/fm-install-shellcheck.sh "$PWD/.tasktmp/runner/bin"
/usr/bin/time -f 'lint_wall_seconds=%e lint_user_seconds=%U lint_system_seconds=%S lint_maxrss_kb=%M' env PATH="$PWD/.tasktmp/runner/bin:$PATH" bin/fm-lint.sh
for test_script in tests/*.test.sh; do start=$(date +%s); "$test_script"; end=$(date +%s); printf '%s\t%s\n' "$((end - start))" "$test_script"; done
```

The monolithic lint invocation took 432.23 seconds wall, 413.11 seconds user, 17.11 seconds system, and 2,587,124 KiB maximum RSS.
The serial behavior inventory took 1,389 seconds wall across 87 files under concurrent host load.
Four unrelated, host-dependent tests failed in that local measurement because ambient quota and Pi/session fixtures differed from GitHub; all other 83 files passed, and the runner work did not alter those contracts.
The longest measured files were `fm-pr-check-security.test.sh` at 216 seconds, `fm-backend-herdr-presentation-e2e.test.sh` at 188 seconds, `fm-watcher-lock.test.sh` at 103 seconds, `fm-watch-triage.test.sh` at 95 seconds, and `fm-secondmate-harness.test.sh` at 95 seconds.

Longest-processing-time assignment of the complete inventory plus the new runner regression suite produced estimated shard totals of 348, 348, 347, and 347 seconds on that loaded host.
The checked-in manifest records that assignment and `bin/fm-test-run.sh --list --shard N/4` proves every current `tests/*.test.sh` file appears exactly once before any shard starts.

## After, 2026-07-22

Run these commands from a clean worktree with the pinned ShellCheck on `PATH`.

```sh
/usr/bin/time -f 'lint_wall_seconds=%e lint_user_seconds=%U lint_system_seconds=%S lint_maxrss_kb=%M' bin/fm-lint.sh
```

The implementation-run result below used the same host as the worktree baseline.

The clean canonical lint after-run took 333.12 seconds wall, 458.80 seconds user, 18.93 seconds system, and 2,586,640 KiB maximum RSS.
That is a 22.9% wall-time reduction from 432.23 seconds, with deterministic toolbelt-then-tests output and failure propagation from either bounded worker.
The longer tests group remained the 333-second local critical path; the toolbelt/backend group separately measured 130.52 seconds during implementation.

Local concurrent behavior shards are intentionally unsupported because an implementation experiment reproduced shared-host interference across suites that are isolated on GitHub-hosted matrix runners.
The safe local default remains a complete serial run, while `--shard N/4` is available for focused parity with one isolated CI job.
Hosted after-run timing is recorded after the first branch CI run below.

Fork validation run `29891267218` on commit `cf9d6b5` passed every CI job.
End-to-end behavior job durations were 4:43, 2:08, 4:15, and 5:05 for shards 1-4, followed by the three-second canonical aggregate check.
That reduced the behavior critical path from about 13:02 to about 5:08, or 60.6%, before a hosted-data rebalance.
The hosted lint job completed in 4:34 versus the 6:21 audit baseline, a 28.1% reduction.

The successful run emitted one duration for each of all 88 behavior files.
Longest-processing-time reassignment of those hosted measurements totals 236, 235, 235, and 235 test seconds for shards 1-4 before setup and cleanup.
The manifest now records that hosted-data assignment rather than the original loaded-worktree estimate.

Fork validation run `29891572329` on commit `5f251e1` passed the rebalanced manifest and every CI job.
Shard job durations compressed to 4:01, 4:06, 4:08, and 3:58, with the canonical aggregate completing in three seconds after the slowest shard.
The resulting behavior path is about 4:11, 67.9% below the 13:02 baseline, and the shard spread is ten seconds.
Lint completed in 4:26, becoming the overall workflow critical path while remaining 30.2% below its 6:21 baseline.
The overall critical path therefore moved from about 13:02 to 4:26, a 66.0% wall-time reduction with the complete behavior and lint contracts green.

After rebasing onto `622d467`, fork validation run `29892663321` passed the integrated 90-suite inventory, canonical timed runner and JSON artifacts, stock macOS Bash listing probe, aggregate check, repository invariants, and lint.
Shard jobs completed in 3:58, 4:02, 3:50, and 3:32, the aggregate in four seconds, lint in 3:17, and the stock macOS lane in 1:24.
All 90 emitted per-suite timing records were then reassigned with the same longest-processing-time algorithm, producing estimated test-body totals of 220.629, 220.643, 220.625, and 220.628 seconds; `tests/behavior-shards.txt` records that 18-millisecond-spread assignment.
Upstream then advanced to `14c0d5f` with `tests/fm-pending-reply.test.sh`; its focused local run passed in 12.91 seconds.
Reapplying longest-processing-time assignment to that measurement and all 90 hosted records produced 91-suite estimated totals of 223.860, 223.859, 223.859, and 223.857 seconds, a three-millisecond spread before hosted setup and cleanup.
