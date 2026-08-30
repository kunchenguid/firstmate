# LOOP.md — how firstmate runs as loops

Spec: docs/specs/2026-07-03-loop-conformance.md (loop-engineering conformance).
This file documents the loops that ACTUALLY run — it is descriptive, not
aspirational. The loop vocabulary is cobusgreyling/loop-engineering.

## Active loops

### 1. Watcher wake loop (the heartbeat)

`bin/fm-watch.sh`, armed as a self-verifying singleton by `bin/fm-watch-arm.sh`.
Zero-token by design: pure bash, sleeps, exits with one reason line —
`signal` (a crewmate appended to a status file), `stale` (an in-flight task
went quiet), `check` (a state/<id>.check.sh poll fired, e.g. PR merged), or
`heartbeat`. Every wake is recorded durably in `state/.wake-queue` before
suppression markers advance; `bin/fm-wake-drain.sh` drains the queue atomically
at the start of each firstmate turn and appends one JSON line per drain to
`loop-run-log.md` (disable: `FM_LOOP_LOG=0`).

- Cadence: event-driven + heartbeat (see fm-watch.sh intervals).
- State: `STATE.md` (Last run stamp + watch list), `state/.wake-queue`,
  `state/<id>.status`.
- Maker/checker: the woken firstmate session is the maker; the Quarterdeck
  (`bin/fm-verify.sh`, default-REJECT) is the checker for every ship task —
  see `.claude/agents/loop-verifier.md`.

### 2. Supervise daemon (away mode)

`bin/fm-supervise-daemon.sh`, presence-gated (/afk). Self-handles routine
wakes, batches escalations for the captain. Runs only while the captain is
away; its churn stays out of the captain-facing status channel.

### 3. Context watchdog

`bin/fm-context-watch.sh` (gates g1–g5): selects over-threshold sessions
(captain ≥185k tokens, crew ≥50%), fires checkpoint→handoff→/clear→rehydrate
on idle panes only (busy-guard).

## Verification chain (both ends of every ship task)

Wardroom at intake (`bin/fm-intake.sh` — a brief cannot spawn without a
`proceed:`), Quarterdeck at delivery (`bin/fm-verify.sh` — `done:` is a claim;
merge/pr-check refuse without an `approve:`). Both fail closed. Escalation
after bounded retries (3 rejects / 2 revises) — no infinite fix loops.

Only a blocking defect holds a spawn: everything else is a note carried on the
proceed (`proceed-with-notes`). A gate that can never pass is indistinguishable
from one that is broken, so intake reads its own record on every decision and
warns when the proceed rate is zero over the most recent decisions — a fault in
the bar, not proof the briefs were bad.

## Budget

The watcher itself spends zero tokens; the budget is wake discipline. Tokens
are spent by the firstmate session each wake and by council calls
(thinkers/verifier/lens). Caps and the kill switch live in `loop-budget.md`;
per-wake accounting is `loop-run-log.md`. Binding operational rules:
`loop-constraints.md`.

## Readiness

Scored by `loop-audit` (global install: `npm i -g @cobusgreyling/loop-audit` —
gate-l2 exits 2 with this hint when it is missing, the same fail-closed
pattern as the `ledger` CLI). gate-l2 pins level ≥ L2. L3 is claimed only when
`loopActivity` is earned by real instrumented wake drains — never asserted.
Loop observability is main-home-only: secondmate homes (marked
`.fm-secondmate-home`) skip run-log/STATE writes, keeping their churn out of
fleet fast-forward syncs.
