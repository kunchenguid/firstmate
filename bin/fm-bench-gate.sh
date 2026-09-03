#!/usr/bin/env bash
# fm-bench-gate.sh - run one model-routing benchmark gate.
#
# The three-track benchmark's independent adversarial review found that the
# design's promises were prose, not enforcement: repeated packets were counted
# as independent samples, judge panels differed per candidate, blinding hid
# labels but did not prevent sibling access, the evaluator was a description,
# historical security provenance was never positively established, the run and
# cost arithmetic did not add up, and a git bundle alone could not be rejudged
# after cleanup. These gates are the enforcement half.
#
# Every gate recomputes its own evidence rather than reading a declared verdict:
# content addresses are recomputed from stored bytes, run and judge counts are
# derived from the frozen plan, isolation probes are actually executed inside
# the declared confinement, and archived bundles are actually restored into a
# fresh repository and rebound to their recorded tree.
#
# Usage:
#   fm-bench-gate.sh [--bench <dir>] [--probe-timeout <s>] <gate>
#   fm-bench-gate.sh --help
#
# Pre-launch gates, all of which `preflight` composes:
#   plan-check        explicit track capabilities, six distinct packets, the
#                     six-task sweep rule, a common neutral judge panel, no
#                     adaptive ninth sample, and the captain's fixed rulings
#   freeze / freeze-check
#                     require every planned private input, freeze it before
#                     labels exist, then prove the inputs are unchanged
#   provenance-check  positive coverage of every original author, reviewer,
#                     and judge before a historical packet is replayed
#   isolation-verify  run the sibling-access probe set inside each entrant's
#                     network-disabled confinement, verify a separate provider-
#                     proxy runtime wrapper for launch, prove its in-root
#                     private paths are ignored by Git, and refuse unless every
#                     probe is denied
#   evaluator-verify  environment lock, published score map, zero-weight
#                     validity gates, confined content-addressed executions,
#                     frozen content-addressed inputs, derived mutation
#                     calibration, and one capture per planned head
#   evaluator-execute-verify
#                     run the evaluator proof used by preflight directly
#   manifest-build / manifest-check
#                     derive the exact run, judge, capture, timing, failure,
#                     allowance, and low/base/high cost arithmetic from the plan
#   preflight         all of the above; writes preflight.receipt on a pass
#
# Post-run gates:
#   promote-evaluate  recompute scored-attempt evidence through the plan-owned
#                     composite, accept void-specific failure/timing evidence,
#                     then apply the sweep, margin, and baseline veto
#   archive-verify    require one terminal scored attempt per planned identity,
#                     retain linked prior void attempts, and verify regular
#                     self-contained content-addressed evidence
#   restore-drill     restore each bundle into a fresh repository, rebind its
#                     tree, then rerun a deterministic archived evaluator twice
#                     with its declared structured perturbation in confined,
#                     independent scratch copies whose content and settable
#                     metadata differ only at the declared input
#   cleanup-gate      authorise candidate and snapshot cleanup only from a
#                     passing drill still bound to the archive as it stands
#
# Exit codes: 0 pass, 1 refused, 2 usage error, 3 captain-stop. A captain-stop
# is a new fact the captain must rule on - both historical packets failing
# provenance, or a measured high cost above the approved class - and is never
# resolvable by substituting a packet or expanding the budget.
#
# bin/fm-bench-gate.py owns every check, schema key, and exit code; its --help
# owns the benchmark directory layout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/fm-bench-gate.py"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
[ -f "$GATE" ] || { echo "error: gate owner is missing: $GATE" >&2; exit 2; }

exec python3 "$GATE" "$@"
