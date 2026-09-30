# Continuous captain input verification

This record covers opt-in continuous captain input demand, registered through `bin/fm-inbox.sh subscribe`.
`bin/fm-inbox.sh --help` owns registration and the read-only `input-receipts` interface, and [watcher continuity](../watcher-continuity.md#continuous-captain-input) owns the operator contract.
No process-event runner was added because input already has a durable inbox and wake queue; a second result queue would duplicate that ownership.

The runtime pieces are `fm-supervision-lib.sh` (demand), `fm-inbox.sh` (registration and serialized note acknowledgement), `fm-wake-lib.sh` (body-free notification and generation/sequence receipts), `fm-wake-drain.sh` (post-handling receipt call), `fm-watch.sh` plus `fm-input-wait.py` (interruptible idle sleep and scan checkpoints), and `fm-watch-arm.sh` plus `fm-claude-stop-autoarm.sh` (existing delivery and generation handoff).
Without `state/.captain-input`, every path above keeps its existing behavior.

## Native evidence

Measured on 2026-09-25 using Claude Code 2.1.282 and observed `claude-haiku-4-5-20251001`, existing subscription authentication, disposable homes, and a 30-second fleet poll.
Input came from a synthetic external listener in mock mode that wrote inbox notes and read the recorded replies, with no chat service or credentials involved.
The baseline is the same listener running its own independent waiter and acknowledgement path instead of the shared owner, with a six-input idle sample.
Times start at local mock input receipt, not at the chat service's send time.
Nearest-rank p95 for six samples is the maximum; these are smoke measurements, not an SLA.

| Measurement | Shared owner | Separate-waiter baseline |
| --- | ---: | ---: |
| Idle input to reader median | 5,361.992 ms | 2,367.488 ms |
| Idle input to reader p95 | 8,351.968 ms | 4,730.192 ms |
| Idle input to first output median | 2,432.372 ms | 1,217.938 ms |
| Idle input to first output p95 | 2,607.485 ms | 1,225.476 ms |
| Input during a busy turn to reader | 10,637.588 ms | 9,318 ms |

All seven distinct inputs produced exactly one reader receipt, one committed generation handoff, one note-handling receipt, and one shared queue acknowledgement.
The watcher delivery ledger contains exactly seven input deliveries: zero redundant watcher wakes; a five-second observation after idle sampling had zero extra model results.
The queue was empty, all seven notes were handled, and the disposable watcher lock was absent after cleanup.
This removes the competing listener/watcher acknowledgement path seen in the baseline; it does not improve measured latency.
The native run's cumulative reported model cost was $0.049708.
The synthetic listener driver and its raw evidence are not tracked; the portable suites below are the repeatable regression entry point.

## Verification and limits

Run `bin/fm-lint.sh` and `bin/fm-doc-audience-check.sh`.
Run `bin/fm-test-run.sh tests/fm-inbox.test.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-wake-queue.test.sh tests/fm-watch-arm.test.sh tests/fm-watch-recovery-loop.test.sh`.

The new cases cover idle demand without tasks, refusal by an unowned session, simultaneous ordinary input, shared queue acknowledgement, concurrent note acknowledgement, a busy bounded check batch, attached-arm delivery, repeated Stop, interrupted arm and re-arm, supersession, and away/quiet ownership.
Default-off regression behavior remains covered by the existing suites.
The arm suite has a timing-sensitive three-second teardown assertion that can fail under heavy concurrent load and pass alone, including the new input delivery bound.

The notification helper only interrupts blind idle sleeps and is checked between scan units; an in-progress bounded check and a backend-native event wait keep their existing timeout.
The attached-arm optimization requires the exact watcher PID/identity delivery receipt and applies only to registered input.
The CLI and receipt fields do not claim exactly-once external actions or that a committed hook request reached the model.
A process death between commit and exit retains the existing durable replay behavior.

Input ownership checks apply to note and input-wake acknowledgement; ordinary event and branch drain authority is unchanged.
Registration does not authenticate an external human, end away mode, clear quiet, or change daemon/branch ownership.
The native proof covers attended Claude; other supported harnesses and backend event waits were inspected at their shared integration surfaces but were not revalidated live.
As in the existing Stop owner, a vendor hook timeout retains queued input and requires a subsequent Stop/session event to re-arm; this does not add an independent timeout-repair service.
A probe on the same installed Claude version observed no native StopFailure receipt after an injected provider error; this change neither depends on that event nor claims to fix it.

## Latency profile

A same-day profile of the unchanged implementation used the same Haiku model, prompt, reader, six idle inputs, and one busy input.
Lab-only file timestamps marked input checkpoints, successor confirmation, and generation commit; reader timestamps separated drain from listener acceptance.
No profiling hooks are part of the tracked runtime.

| Profiled interval | Median |
| --- | ---: |
| Input to watcher checkpoint | 190 ms |
| Checkpoint to successor start | 463 ms |
| Successor confirmation | 648 ms |
| Confirmation end to handoff commit | 194 ms |
| Handoff commit to first model output | 1,010 ms |
| First model output to reader process start | 1,799 ms |
| Reader drain | 497 ms |
| Drain completion to listener acceptance | 650 ms |

Interval medians are independent and should not be summed as a measured whole-turn percentile.
The profiled run measured 5,606.436 ms idle median, 9,331.920 ms p95, and 10,677.987 ms busy input-to-reader latency, with the same one-receipt-per-input and zero-redundant-wake results as above.
The median from committed handoff to reader acceptance alone was 4,082.321 ms, so the scan checkpoint and successor grace are not the dominant remaining delay.
Two timing candidates were measured and rejected: a shorter input-specific banner did not reach a 2,400 ms idle median, and a faster startup confirmation with an interruptible attached-owner wait left one busy input undelivered to the reader within 60 seconds, though it stayed durable in the queue.
Exactly-once handling was not relaxed, and no faster production guarantee is claimed.
Further latency work belongs in model/tool-call generation, reader integration, and busy-turn native handoff behavior rather than the watcher.
