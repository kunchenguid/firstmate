# Test lane safety

Active evidence for the three containment guarantees `bin/fm-test-run.sh` makes about every test script it runs, and for the fork/exec settling `tests/lib.sh` provides.
`bin/fm-test-run.sh` remains the single owner of lane composition and execution; this file records what was measured, on what, and which regression re-checks it.

## Why the containment exists

A single test-started process that outlives its script is enough to stop an entire lane indefinitely, with no diagnostic at all.

Observed on 2026-08-18 on Linux 6.6.87.2-microsoft-standard-WSL2 with GNU bash 5.2.21: `bin/fm-test-run.sh --lane portable-serial-3of4` was still alive after 7h23m with its output frozen.
Its process tree was the lane runner, the test script, a `bin/fm-watch-arm.sh`, that arm's `bin/fm-watch.sh` child, and a `sleep`, alongside the lane's own `tee`.
The last line the lane printed before it froze was:

```
<worktree>/bin/fm-watch.sh: trap: line 2: unexpected EOF while looking for matching `)'
```

A second orphan, from `tests/fm-watch-triage.test.sh`, had already been reparented to init with its scratch state directory deleted, so its own cleanup had run and only the process outlived it.
Its file descriptor 2 was still the lane's stdout pipe: `/proc/<orphan>/fd/2` and `/proc/<tee>/fd/0` named the same pipe inode, so `tee` never saw end of file and the lane blocked on it forever.

That second orphan is a different failure from the first and needs its own fix.
The temp root is removed by an `EXIT` trap, so it disappears on every path, while a reap written as a plain statement after the spawn runs only on the path that reaches it.
Several cases in that script assert between starting a watcher and stopping it, and `fail` exits the script immediately, so on a failing assertion the watcher is never signalled at all.
Escalating a swallowed `TERM` does nothing for that case, because no signal is ever sent; only registering the PID with the same trap that removes the temp root makes the reap unconditional.
`tests/fm-test-run.test.sh::test_test_helper_reaps_processes_a_failing_script_left_running` pins exactly that path.

## What that diagnostic does and does not mean

Bash prints `<script>: trap: line N: <parse error>` when it fails to parse a signal trap's action string at delivery time, and `N` is one more than the line of the action string itself.
The important part is what the shell does next, which is measurable:

```
$ cat t.sh
#!/usr/bin/env bash
trap 'foo=$(bar' TERM
sleep 30
echo after
$ bash t.sh & p=$!; sleep 0.3; kill -TERM $p; wait $p; echo "rc=$?"
t.sh: trap: line 2: unexpected EOF while looking for matching `)'
after
rc=0
```

The action never runs and the shell keeps going, so the signal is swallowed.

The action strings the watcher actually installs are not malformed.
Every `trap` call made anywhere in the watcher process tree during one full `tests/fm-watcher-lock.test.sh` run was captured on 2026-08-19 by pointing `BASH_ENV` at a wrapper that logs its arguments and then calls `builtin trap`.
That census recorded 252 installs and exactly five distinct action strings: `exit 1`, `watcher_cleanup`, `FM_CHECK_SIGNAL_PENDING=1`, `[ -z "$TMP" ] || rm -f -- "$TMP"`, and the empty string.
None of them contains an unbalanced parenthesis, and none is built by interpolation, so the failure is in the re-parse at delivery, not in the string as written.

The operational conclusion is therefore not "fix the string" but "do not depend on a single TERM being honoured".
Every reap in the test tooling escalates TERM to KILL after a bounded grace and verifies the process by PID, and no reap waits on a child without a bound.
That is what turns a swallowed signal from a lane-wide multi-hour hang into a reported and reaped leak.

## Guarantees and their regressions

| Guarantee | Regression |
|---|---|
| A descendant that outlives its script never holds the lane's own output stream, and the lane waits only on the PID it started. | `tests/fm-test-run.test.sh::test_lane_reaps_a_leaked_child_and_keeps_going` |
| A script that stops making progress is terminated at the per-script budget and reported by name with `exit=124`. | `tests/fm-test-run.test.sh::test_lane_times_out_a_hung_script_and_names_it` |
| Replacing the shared pipe with a private file and a follower keeps every byte of stdout and stderr, in order. | `tests/fm-test-run.test.sh::test_lane_output_is_complete_and_ordered_without_a_shared_pipe` |
| A process a test registers is reaped even when the test fails before its own reap runs. | `tests/fm-test-run.test.sh::test_test_helper_reaps_processes_a_failing_script_left_running` |
| Sampling a freshly backgrounded process waits for `execve` to publish the exec'd image. | `tests/fm-watcher-lock.test.sh::test_pid_identity_sampling_waits_for_execve` |

## Measured before and after

Run on 2026-08-19, Linux 6.6.87.2-microsoft-standard-WSL2, GNU bash 5.2.21.

The fixture is a script that exits zero after leaving one child holding its stdout and ignoring `SIGTERM`, followed by a second script that must still run.

With the runner at the pre-change revision the lane produced one line and then hung until an external 45s timeout killed it, printing no `FM_TEST_END`, no summary, and never reaching the second script.
With the current runner the same fixture completes in 5.5s: the leak is reported as `FM_TEST_LEAK`, the child is reaped, the leaking script keeps its own `exit=0`, and the second script runs.

The `execve` settling was measured by widening the fork-to-exec window deliberately with `bash -c 'sleep 0.25; exec sleep 300'` and taking the same two identity samples the locale test takes.
Without the settle wait the two samples differed in 30 of 30 iterations; with it they differed in 0 of 30.

## Refreshing this record

Re-run the regressions above with `bin/fm-test-run.sh tests/fm-test-run.test.sh tests/fm-watcher-lock.test.sh`.
Re-run the before-and-after measurement only when the containment mechanism itself changes, and re-take the trap census with the `BASH_ENV` wrapper if a future diagnostic again blames a trap action string.
