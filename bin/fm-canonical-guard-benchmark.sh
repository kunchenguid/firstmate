#!/usr/bin/env bash
# Build and operate the pre-registered canonical-guard benchmark harness.
#
# Usage:
#   fm-canonical-guard-benchmark.sh init --workspace DIR --source ARTEMIS --ref SHA
#   fm-canonical-guard-benchmark.sh fixture-check --workspace DIR
#   fm-canonical-guard-benchmark.sh freeze --workspace DIR --file PLAN.json
#   fm-canonical-guard-benchmark.sh run --workspace DIR --run-id ID --arm guard-on|guard-off \
#     --harness codex|claude|cursor-agent|kimi|pi --model MODEL --prompt-file FILE \
#     [--effort LEVEL] [--stage smoke|matrix] [--lane ID] [--helper-family FAMILY] \
#     [--max-load N] [--load-file FILE] [--timeout SECONDS]
#   fm-canonical-guard-benchmark.sh score --workspace DIR --run-id ID --semantic-file FILE
#   fm-canonical-guard-benchmark.sh record-verdict --workspace DIR --file FILE
#   fm-canonical-guard-benchmark.sh schema-check --workspace DIR
#   fm-canonical-guard-benchmark.sh scoreboard --workspace DIR --markdown FILE --html FILE
#
# `init` creates a disposable filesystem-only bare remote and two installed
# templates whose tracked trees differ only by deletion of the
# canonical-boundaries command block.  It never writes to the source checkout.
# `freeze` records the ratified prompt, slate, axes, and amendment exactly once.
# `run` holds one lane lock, admits on one-minute load, uses copy-on-write,
# strips forge credentials, captures Git/session/usage evidence outside the run
# worktree, and removes the worktree after capture.  Matrix axes must match the
# frozen plan exactly, and a run never scores itself.
# `score` is post-matrix only, reconstructs the final tree from captured evidence,
# runs the pinned detector, requires two independent semantic verdicts, and
# appends one immutable verdict to the separate workspace verdict ledger.
# `scoreboard` derives every displayed number from manifests and that ledger.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$ROOT/scripts/canonical-guard-benchmark/benchmark.py" "$@"
