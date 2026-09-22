#!/usr/bin/env bash
# fm-jev-fleet-eval.sh - Shell wrapper for Jev System One Fleet Evaluator.
#
# Runs continuous semantic evaluation of fleet health, blocker patterns, and
# harness runway via https://api.typesafe.ai/v1/systemone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-fleet-eval.py" "$@"
