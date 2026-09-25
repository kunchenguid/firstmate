---
name: wake-admission
description: >-
  Agent-only procedure for the per-wake admission step in AGENTS.md section 8.
  Load before the first admission step of a session and whenever a headroom term, its measurement, or the bound to report is unclear.
  Owns the actor scope, the headroom terms and their owners, unknown-headroom handling, admission order, and the one-line summary's vocabulary and channel.
user-invocable: false
metadata:
  internal: true
---

# wake-admission

`AGENTS.md` section 8 owns the rule that every wake ends with admission and one summary line.
This skill owns how to run that step.
It adds no scheduler: every admission is an ordinary section 7 intake that ends in `bin/fm-spawn.sh`, whose guards still refuse anything the step gets wrong.

## 1. Who runs it

Only the session that holds this home's fleet lock and owns its supervision runs admission.
A lock-refused read-only session never runs it, because it may not spawn.
In away or quiet posture, the actor that section 8's stub says takes wakes runs admission within the away spend cap, and a parked main does not.
Admission is per home: each home admits only from its own backlog, and a secondmate's backlog holds only work routed to it, so a secondmate admits routed work and never invents any.
The session-start turn runs the step once after handling its presented queue; that is the same step, not an extra one.

## 2. Dispatchable rows

`fm_backlog_row_dispatchable` in `bin/fm-backlog-transition-lib.sh` owns which backlog states can dispatch, and `bin/fm-spawn.sh` refuses any other row.
Exclude as well any row whose section 10 time gate has not yet passed.
Count those rows in backlog priority order; that count is `dispatchable`.

## 3. Headroom terms

Each term maps to one `bound` value.

- `headroom` - the resource floor.
  The owner is the operator-recorded floor and per-worker cost in this home's `data/captain.md`.
  Measure it at admission time from the platform's available-memory figure, such as `MemAvailable` in `/proc/meminfo` on Linux, and compare it against the floor plus the cost of each row you are about to admit.
  With no recorded floor, or when the figure cannot be read, headroom is unknown: disclose that in the summary turn and count it as greater than zero, never as zero, as section 4 treats unmeasurable headroom.
- `quota` - provider quota.
  The owner is the section 4 intake for each row, meaning `quota-axi` and `quota-array-dispatch` where a profile array matches.
  A row whose required reasoning class cannot proceed on current quota binds `quota`.
- `slots` - counted concurrency slots.
  The owners are the away spend cap (`bin/fm-afk-contract.sh`'s `spend_max_concurrent_workers`, enforced by `bin/fm-spawn.sh`) and any captain-recorded concurrency limit in `data/captain.md`.
  A section 7 serialization, a true dependency on live work, also binds `slots` for that row.

## 4. Admission order

Walk the dispatchable rows in backlog priority order and run the full section 7 intake on each in turn, including section 4 profile resolution.
Keep each row's required reasoning class.
When that class cannot proceed within the remaining headroom, stop and report that row rather than downgrading it to fill the headroom.
A row whose intake needs a captain decision is escalated or held under section 10 and is not counted as admitted.
Stop at the first limit that binds; that limit is the reported `bound`.

## 5. The summary line

Write `dispatchable=N admitted=M bound=<headroom|quota|slots|none>` once in the turn's transcript.
Never append it to a task status file, because each status append wakes the supervisor.
Report `bound=none` when every dispatchable row was admitted, including when `dispatchable=0`.
When `admitted` is below `dispatchable`, name in the same turn the row that stopped admission and why: the bound hit, an unknown headroom figure you disclosed, a section 10 escalation or hold, or a section 4 stop-and-report.
Stating that cause is what separates a correct zero-admission turn from the failure section 8 names.
