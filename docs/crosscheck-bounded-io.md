# Crosscheck bounded I/O

Crosscheck treats every external byte stream, artifact, item collection, and process tree as hostile to availability.
The shared implementation is `bin/fm_bounded_io.py`.

One absolute deadline covers command execution, output draining, final wait, and cleanup.
Stdout and stderr share one aggregate byte ceiling, and a retained supervisor anchor owns cleanup after either failure or a successful command exit.
Linux uses a child subreaper, which atomically adopts orphaned descendants before identity-pinned cleanup.
macOS has no equivalent containment boundary in this implementation, so cleanup there is best effort: it covers descendants observed by the periodic census, processes that remain in the supervisor group, and processes that retain the inherited ownership marker.
A macOS descendant can escape that coverage by detaching and replacing its environment before any census observes it; callers must not treat macOS cleanup as durable containment of hostile commands.
The anchor is not reaped until cleanup of the processes within the platform's stated coverage is verified, and an unsupported or unprovable cleanup attempt fails closed.
Structured artifacts must be stable regular files within a byte ceiling before decoding, and decoded depth, item count, string bytes, and numeric finiteness are validated separately.
Artifact opens are nonblocking and no-follow, and the opened descriptor must remain a regular file with the device and inode observed before opening.
Review and evidence batches share a deadline and item counter rather than multiplying a per-item timeout by repository-controlled array length.

These controls close a recurring fleet failure class: a nominal limit does not provide a bound when an alternate byte channel, descendant process, or repeated item can bypass it.
The defects were found by deeper review of the pre-fix branch; they were not caused by the preceding eight-finding fix round.
That is good news about those fixes, but it also records unusually high defect density in the original Crosscheck review surface.

The deterministic suite is `tests/fm-bounded-io.test.sh`.
Every named case can run independently so mutation evidence can prove that it becomes red when its corresponding bound is removed.

## Mutation evidence

The original six named cases and the concurrent artifact-open race regression were executed under the following mutations on 2026-08-03 and restored before the final green run.

| Named case | Executed mutation | Observed red result |
| --- | --- | --- |
| `output-limit` | Replaced the aggregate `captured > output_limit` guard with an unreachable condition. | `FAIL: noisy process crossed the aggregate output ceiling` |
| `final-wait` | Extended the command deadline beyond the declared wall-clock deadline. | `FAIL: closed output pipes escaped the command deadline` |
| `residual-group` | Skipped process-group cleanup after a successful leader exit. | `FAIL: successful leader left residual process ... alive` |
| `artifact` | Disabled both encoded artifact byte checks and read through the declared ceiling. | The expected byte-limit diagnostic disappeared, so the named case failed through the independent decoded-string ceiling. |
| `artifact-open-race` | Removed `os.O_NONBLOCK` from the artifact open flags. | `AssertionError: concurrent FIFO replacement blocked during open` |
| `decoded-strings` | Disabled decoded key and value string-byte accounting. | `FAIL: decoded strings bypassed their aggregate ceiling` |
| `batch-items` | Disabled the incremental item-count guard. | `AssertionError: batch item ceiling was not enforced` |
