#!/usr/bin/env bash
# tests/fm-jev-fleet-eval.test.sh - Verification suite for Pattern 7 Jev Fleet Evaluator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVAL_BIN="$FM_ROOT/bin/fm-jev-fleet-eval.sh"

echo "1. Verify --help output..."
"$EVAL_BIN" --help >/dev/null
echo "ok - help flags work"

echo "2. Verify --json output format..."
JSON_OUT=$("$EVAL_BIN" --json)
if ! printf '%s\n' "$JSON_OUT" | grep -q '"fleet_health_score"'; then
  echo "FAIL: Expected fleet_health_score in JSON output" >&2
  exit 1
fi
if ! printf '%s\n' "$JSON_OUT" | grep -q '"primary_bottleneck"'; then
  echo "FAIL: Expected primary_bottleneck in JSON output" >&2
  exit 1
fi
echo "ok - live Jev evaluation JSON format verified"

echo "ok - all fm-jev-fleet-eval tests passed"
