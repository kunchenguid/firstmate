---
name: model-routing-benchmark
description: >-
  Agent-only procedure for the three-track model-routing benchmark.
  Use before launching, judging, promoting, or cleaning up any benchmark entrant, and on any benchmark gate refusal.
  Owns the launch order, the two captain-stop conditions, and the rule that a gate refusal is investigated rather than bypassed.
user-invocable: false
metadata:
  internal: true
---

# model-routing-benchmark

Load this before any benchmark entrant is launched, before judging or promoting a benchmark result, before candidate or snapshot cleanup, and whenever a benchmark gate refuses.

The benchmark decides standing routes, so its result changes how every future task is dispatched.
An independent adversarial review found the original design's safety properties were promises rather than enforcement, and its correction set is now executable.
`bin/fm-bench-gate.sh --help` owns the gates and the benchmark directory layout; `docs/model-routing-benchmark.md` owns why each gate exists.

## Launch order

Run the gates in this order, because each one's evidence depends on the last.

1. `manifest-build`, then read the derived counts.
   The plan, not a quoted estimate, owns how many runs, judge calls, captures, and dollars this benchmark is.
2. `freeze`, before any label is assigned.
   A freeze attempted after `key.json` exists is refused, and that refusal is correct.
3. `preflight`, which composes plan, freeze, provenance, isolation, evaluator, and manifest, and writes the receipt.
4. Only then spawn entrants, with `FM_BENCH_ROOT` set.
   `bin/fm-spawn.sh` refuses a `bench-` task id that no passing receipt covers.

After the runs: `promote-evaluate`, then `archive-verify`, then `restore-drill`, then `cleanup-gate`.
Cleanup is refused until the drill has really restored every bundle, and the receipt stops covering the archive the moment one archived byte changes.

## A refusal is a finding

Every refusal names the correction it protects.
Treat it as a diagnostic result, not an obstacle: fix the evidence, never the threshold.

Specifically, do not "resolve" a refusal by relaxing the plan.
The launch receipt is bound to `benchmark.json`'s bytes, so editing the plan after a pass invalidates the receipt rather than clearing the entrant, and that binding is the point.
If a gate looks wrong, the failing case belongs in `tests/fm-bench-gate.test.sh` before the check changes.

## The two captain-stop conditions

Exit code 3 means a new fact only the captain can rule on.
Neither may be settled by substituting a packet, deferring part of the field, or expanding the budget:

- every historical packet in a track fails its contamination check, and
- the measured high-cost case exceeds the approved cost class.

Escalate the concrete fact and the option set, and hold the entrants.

## Fixed rulings the gates already encode

These are the captain's, not yours to revisit at intake: six distinct packets per entrant with three baseline veto samples, enforced per-entrant isolation with negative sibling-access tests, common neutral judge panels, positive provenance before any historical security replay, one complete UI wave rather than a partial field, no adaptive ninth sample, and every candidate archived and then discarded with nothing shipping directly.
A benchmark result never enters product delivery: a wanted plan or fix re-enters ordinary intake as new work.
