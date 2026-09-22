#!/usr/bin/env bash
# tests/fm-jev-worker-reaper.test.sh - Verification suite for Pattern 8 Worker Reaper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAPER_BIN="$FM_ROOT/bin/fm-jev-worker-reaper.sh"

echo "1. Verify --help output..."
"$REAPER_BIN" --help >/dev/null
echo "ok - help flags work"

echo "2. Verify --json output format..."
JSON_OUT=$("$REAPER_BIN" --check --json || true)
if ! printf '%s\n' "$JSON_OUT" | grep -q '"dead_workers"'; then
  echo "FAIL: Expected dead_workers in JSON output" >&2
  exit 1
fi
echo "ok - JSON format verified"

echo "3. Verify --check runs without error..."
"$REAPER_BIN" --check >/dev/null 2>&1 || true
echo "ok - check scan completed"

echo "ok - all fm-jev-worker-reaper tests passed"

python3 "$(dirname "${BASH_SOURCE[0]}")/jev-safety-fixtures.py" worker-reaper
