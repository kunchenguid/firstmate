# No-mistakes reattach timeout

This note records the 2026-08-01 characterization of three reattach failures under a roughly 30-agent fleet load and the boundary between the local firstmate mitigation and the upstream no-mistakes repair.

## Observed mechanism

The three affected lanes were `audit-evidence-m7`, `retention-erasure-d8`, and `kafka-isolation-p6`.
The captured failure was `drive run: reconcile run <id>: read response: read unix -><NM_HOME>/socket: i/o timeout` on no-mistakes v1.41.2 (`867d64d`).
The first two lanes recovered after another attach and the third stopped, proving that the run remained attachable after at least two occurrences but that the client performed no reliable outer retry.
An independently repeated machine-level load measurement found an operational ceiling of about five concurrent no-mistakes pipeline runs.
During the incident, five lanes across two firstmate homes were parked; [the stalled-lane recovery report](stalled-lane-recovery-2026-08-01.md) owns their inventory and recovery disposition.
That measured ceiling establishes the shared-contention symptom, not the exact query responsible for any individual timeout.

At tag v1.41.2, `internal/cli/run_reconciler.go` retries subscription connection failures for up to 30 seconds, but `reconcile` returns the first `get_run` failure immediately.
`internal/ipc/client.go` applies a 30-second read deadline to that `get_run` call and renders a missed response as `read response: ... i/o timeout`.
The distinct connect-timeout path renders `daemon socket <path> did not accept a connection within <duration>`, so the incident signature proves that the Unix socket connection was already established and the timeout occurred while awaiting the run snapshot.

The daemon's `get_run` handler in `internal/daemon/daemon.go` reads the run and its steps, then `runToInfo` calls `StepFindingStats`, `StepFixSummaries`, and `StepRoundStats` for every step.
Each of those three helpers independently reloads all rounds for that step.
A normal nine-step run therefore expands one reconciliation into 29 serialized database queries: one run read, one step-list read, and three round reads for each of nine steps.
`internal/db/db.go` configures `SetMaxOpenConns(1)`, so every daemon query and mutation shares one Go database connection even though SQLite uses WAL.

The directly established failure mechanism is an accepted-socket response-latency timeout on an N+1 run snapshot serialized through the daemon's singleton database connection.
Concurrent attach heartbeats and state transitions amplify that queue; once a snapshot response takes longer than 30 seconds, the reconciler drops the lane on its first read error.
The available incident data does not identify the exact query that occupied the singleton connection during each occurrence because v1.41.2 records neither handler duration nor connection-pool wait.

This evidence does not match a reattach registration race because subscription succeeds before the failing reconciliation and the error names `reconcile run`.
It does not match a client descriptor-limit failure because the connection was established, the machine soft descriptor limit was 8192, and no `EMFILE` or `ENFILE` error was observed.
It does not establish that descriptor pressure was absent elsewhere in the daemon, so upstream latency instrumentation remains necessary for exact per-occurrence attribution.

## Local firstmate mitigation

`bin/fm-no-mistakes-reattach.sh <id>` resolves the lane exclusively from the selected `FM_HOME`, verifies its canonical worktree and branch identity, and invokes reattach without an intent so it cannot create a fresh run.
Before each attempt it uses the read-only AXI home view to require the daemon to report running.
It retries only the exact reconciliation socket-read timeout with bounded exponential backoff and deterministic per-task jitter.
It never directly calls daemon start, stop, restart, update, abort, or rerun.
Any other error returns immediately.
This is containment, not a strict no-start guarantee: ordinary `axi run` calls `EnsureDaemon`, so a daemon that stops after the read-only preflight can be started during the check-to-use race.
Only an upstream attach-only operation that never starts, stops, restarts, or updates the daemon can close that race.

`bin/fm-crew-state.sh`'s header owns the exact remote-only, fail-closed PR-ready currentness contract; the verification below records the evidence for it.

## Verification

`bash tests/fm-no-mistakes-reattach.test.sh` induced the exact first-attempt socket timeout, observed a second `axi run` reattach return `outcome: checks-passed`, and confirmed that the helper issued no explicit daemon lifecycle subcommand; it does not claim that `EnsureDaemon` inside `axi run` is lifecycle-free.
It separately induced three consecutive timeouts and observed recovery on attempt four, proving recovery is not tied to the second attempt.
The same suite observed a stopped-daemon preflight refuse without invoking `axi run`, a non-transient error return without retry, and a mismatched task branch refuse before contacting no-mistakes.

`bash tests/fm-crew-state.test.sh` supplied a completed run at head `abc1234` and a live PR at `def5678...`, then observed `state: stale`, `source: run-step`, both head values, and `do not merge`.
The paired matching-head case remained `state: done`.
The suite also created a real remote commit absent from the lane worktree, observed the healthy remote run and PR report `state: done`, fetched that commit into the worktree, and observed byte-for-byte identical output afterward.
It separately observed an unavailable GitHub commit resolution and a status-log-only PR URL both fail closed as `state: unknown` with `do not merge`.
The suite also supplied an earlier completed snapshot while the newest run-list row for the same branch was running and observed `state: stale` with `newer active run exists` and `do not merge`.

The helpers were also exercised directly outside the test harness against throwaway homes.
The reattach command visibly retried one induced stderr timeout, performed a fresh daemon preflight, and returned `outcome: checks-passed` on attempt two; the recorded calls were exactly `axi`, `axi run`, `axi`, `axi run`.
The state command visibly returned `state: stale ... do not merge` for a completed `abc1234` snapshot whose live PR head was `def5678...`.

The source-characterization commands were `no-mistakes --version`, `ulimit -n`, a detached checkout of upstream tag `v1.41.2`, and targeted reads of `internal/cli/run_reconciler.go`, `internal/ipc/client.go`, `internal/daemon/daemon.go`, `internal/db/db.go`, and `internal/db/round.go`.
The installed machine did not have the Go toolchain, so no upstream Go load test was claimed.

## Upstream changes required

Upstream no-mistakes should make `runReconciler.reconcile` retry timeout-classified read failures with context-aware capped exponential backoff and jitter, using a fresh connection on every attempt.
The retry budget should apply identically to the initial attach, reconnect, and later heartbeat reconciliations instead of depending on which attach attempt encountered the timeout.

Upstream should batch round-derived fields for a run into one query or one round scan and remove the current three-queries-per-step snapshot amplification.
It should either give read-only snapshots a separate WAL-compatible read pool or otherwise prevent long mutation work from monopolizing the singleton connection.

Upstream should record bounded `get_run` handler latency and database-pool wait so a future occurrence identifies whether the delay was connection-queue contention, SQLite execution, scheduler starvation, or transport backpressure.

Upstream should add a reattach-only AXI mode that refuses to start a stopped daemon.
Firstmate's read-only preflight prevents deliberate lifecycle mutation, but only an upstream attach-only flag can close the check-to-use race between that preflight and `EnsureDaemon` inside `axi run`.

Upstream should expose an untruncated submitted head and current pipeline head in structured AXI status.
That would let supervisors distinguish a current auto-fix descendant from an older completed run without relying on the rendered short SHA, while the live PR-head comparison remains the final publication check before merge.
