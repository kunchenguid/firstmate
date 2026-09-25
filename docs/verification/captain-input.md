# Continuous Input Lab Notes

This private branch implements an opt-in shared wake owner, with no deployment or upstream contribution.
`bin/fm-inbox.sh --help` owns registration and read-only receipt commands.
No process-event runner was added because input already has a durable inbox and wake queue; a second result queue would duplicate that ownership.

The exact runtime diff is `fm-supervision-lib.sh` (demand), `fm-inbox.sh` (registration and serialized note acknowledgement), `fm-wake-lib.sh` (body-free notification and generation/sequence receipts), `fm-wake-drain.sh` (post-handling receipt call), `fm-watch.sh` plus `fm-input-wait.py` (interruptible idle sleep and scan checkpoints), and `fm-watch-arm.sh` plus `fm-claude-stop-autoarm.sh` (existing delivery and generation handoff).
Focused cases extend the existing inbox, watcher-arm, and Stop auto-arm suites.
Documentation adds this record, its audience classification, and continuity pointers.
No operational-input protocol, posture marker, live configuration, or external transport code changes.

## Native evidence

Measured on 2026-09-25 using Claude Code 2.1.282 and observed `claude-haiku-4-5-20251001`, existing subscription authentication, disposable homes, a 30-second fleet poll, and the merged bridge in mock mode with its independent waiter removed.
The comparison is [the bridge laboratory](https://github.com/lockhartheavyindustries/agent-coordination/pull/64), whose idle sample also had six inputs.
Times start at local mock input receipt, not Slack send time.
Nearest-rank p95 for six samples is the maximum; these are smoke measurements, not an SLA.

| Measurement | This branch | Bridge baseline |
| --- | ---: | ---: |
| Idle input to reader median | 5,361.992 ms | 2,367.488 ms |
| Idle input to reader p95 | 8,351.968 ms | 4,730.192 ms |
| Idle input to first output median | 2,432.372 ms | 1,217.938 ms |
| Idle input to first output p95 | 2,607.485 ms | 1,225.476 ms |
| Input during a busy turn to reader | 10,637.588 ms | 9,318 ms |

All seven distinct inputs produced exactly one reader receipt, one committed generation handoff, one note-handling receipt, and one shared queue acknowledgement.
The watcher delivery ledger contains exactly seven input deliveries: zero redundant watcher wakes; a five-second observation after idle sampling had zero extra model results.
The queue was empty, all seven notes were handled, and the disposable watcher lock was absent after cleanup.
This removes the independently competing desk/watcher acknowledgement path seen in the baseline; it does not improve measured latency.
The native run's cumulative reported model cost was $0.049708.
The native command was `.no-mistakes/desk-input-lab/venv/bin/python .no-mistakes/desk-input-lab/native.py`.
Local raw evidence and the synthetic driver remain in the ignored `.no-mistakes/desk-input-lab/native-v4/` and `.no-mistakes/desk-input-lab/native.py` paths, with no credentials recorded.

## Verification and limits

Run `bin/fm-lint.sh` and `bin/fm-doc-audience-check.sh`.
Run `bin/fm-test-run.sh tests/fm-inbox.test.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-wake-queue.test.sh tests/fm-watch-arm.test.sh tests/fm-watch-recovery-loop.test.sh`.
The local queue suite used a disposable source snapshot with sibling scratch homes because its secondmate fixtures must be outside their code root; all remained inside this task worktree.

The new cases cover idle demand without tasks, refusal by an unowned session, simultaneous ordinary input, shared queue acknowledgement, concurrent note acknowledgement, a busy bounded check batch, attached-arm delivery, repeated Stop, interrupted arm and re-arm, supersession, and away/quiet ownership.
Default-off regression behavior remains covered by the existing suites.
All five named suites passed, along with lint and the documentation audience check.
The arm suite has a timing-sensitive three-second teardown assertion: it failed during concurrent validation and passed alone, including the new input delivery bound.

The notification helper only interrupts blind idle sleeps and is checked between scan units; an in-progress bounded check and a backend-native event wait keep their existing timeout.
The attached-arm optimization requires the exact watcher PID/identity delivery receipt and applies only to registered input.
The CLI and receipt fields do not claim exactly-once external actions or that a committed hook request reached the model.
A process death between commit and exit retains the existing durable replay behavior.

Input ownership checks apply to note and input-wake acknowledgement; ordinary event and branch drain authority is unchanged.
Registration does not authenticate an external human, return an away desk, clear quiet, or change daemon/branch ownership.
The native proof covers attended Claude; other supported harnesses and backend event waits were inspected at their shared integration surfaces but were not revalidated live.
As in the existing Stop owner, a vendor hook timeout retains queued input and requires a subsequent Stop/session event to re-arm; this does not add an independent timeout-repair service.
The prior bridge probe on the same installed Claude version observed no native StopFailure receipt after an injected provider error; this change neither depends on that event nor claims to fix it.
