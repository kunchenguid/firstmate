#!/usr/bin/env bash
# fm-competition-scientist-lab.sh - explicit entry point for the inert,
# synthetic competition-scientist pilot.
#
# Usage:
#   fm-competition-scientist-lab.sh init --workspace <new-dir> \
#     --task grouped-classification|nonlinear-regression|noisy-classification \
#     --controller linear|proposed [limits]
#   fm-competition-scientist-lab.sh run --workspace <new-dir> \
#     --task grouped-classification|nonlinear-regression|noisy-classification \
#     --controller linear|proposed (--fixture | --proposals <jsonl>) [limits]
#   fm-competition-scientist-lab.sh attempt <workspace> --proposal <json> \
#     [--inject-failure syntax|timeout|oom|network]
#   fm-competition-scientist-lab.sh finish <workspace>
#   fm-competition-scientist-lab.sh replay <workspace>
#   fm-competition-scientist-lab.sh smoke --output <new-dir> [limits]
#   fm-competition-scientist-lab.sh --help
#
# The command has no implicit startup path and does nothing unless invoked.
# docs/examples/competition-scientist/README.md owns the safety, controller,
# resource, proposal, and evidence contracts; this header owns only invocation.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
exec python3 "$ROOT/docs/examples/competition-scientist/lab.py" "$@"
