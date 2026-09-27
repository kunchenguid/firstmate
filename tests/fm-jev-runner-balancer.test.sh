#!/usr/bin/env bash
# tests/fm-jev-runner-balancer.test.sh - Regression tests for Pattern 23
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$FM_ROOT/bin"
BALANCER_PY="$BIN_DIR/fm-jev-runner-balancer.py"
BALANCER_SH="$BIN_DIR/fm-jev-runner-balancer.sh"

echo "=== Running fm-jev-runner-balancer test suite ==="

# Test 1: Python syntax check
python3 -m py_compile "$BALANCER_PY"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$BALANCER_SH"
  echo "PASS: Test 2 - ShellCheck clean on wrapper"
else
  bash -n "$BALANCER_SH"
  echo "PASS: Test 2 - bash -n syntax valid (shellcheck not installed)"
fi

# Setup mock data for unit testing
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-runner-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_DATA="$TEST_TMP/mock-ci.json"

cat <<'EOF' > "$MOCK_DATA"
{
  "runners": [
    {
      "id": 1,
      "name": "Portal-agt-10",
      "status": "online",
      "busy": true,
      "labels": [{"name": "portal-ci-linux"}, {"name": "X64"}]
    },
    {
      "id": 2,
      "name": "Portal-agt-11",
      "status": "online",
      "busy": false,
      "labels": [{"name": "portal-ci-linux"}, {"name": "X64"}]
    },
    {
      "id": 3,
      "name": "cvn-runner-01",
      "status": "online",
      "busy": true,
      "labels": [{"name": "covenant-clinic"}]
    },
    {
      "id": 4,
      "name": "Portal-dev-2",
      "status": "online",
      "busy": false,
      "labels": [{"name": "portal-e2e"}]
    },
    {
      "id": 5,
      "name": "Portal-stale-01",
      "status": "offline",
      "busy": false,
      "labels": []
    }
  ],
  "jobs": [
    {
      "databaseId": 1001,
      "name": "Test Suite (1/12)",
      "status": "in_progress",
      "startedAt": "2026-09-21T10:25:00Z",
      "runnerName": "Portal-agt-10"
    },
    {
      "databaseId": 1002,
      "name": "Test Suite (2/12)",
      "status": "in_progress",
      "startedAt": "2026-09-21T09:50:00Z",
      "runnerName": "cvn-runner-01"
    },
    {
      "databaseId": 1003,
      "name": "Test Suite (3/12)",
      "status": "queued"
    }
  ]
}
EOF

python3 - "$MOCK_DATA" <<'PYTEST'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
now = datetime.now(timezone.utc)
for job, minutes in zip(data["jobs"], (5, 40)):
    job["startedAt"] = (now - timedelta(minutes=minutes)).isoformat()
path.write_text(json.dumps(data))
PYTEST

# Test 3: Scan mock runners and jobs, verifying schema compliance
OUTPUT=$("$BALANCER_SH" --mock-data "$MOCK_DATA" --json)

# Validate capacity metrics
echo "$OUTPUT" | grep -q '"total_runners": 5'
echo "$OUTPUT" | grep -q '"online_runners": 4'
echo "$OUTPUT" | grep -q '"offline_runners": 1'
echo "$OUTPUT" | grep -q '"busy_runners": 2'
echo "$OUTPUT" | grep -q '"idle_runners": 2'
echo "PASS: Test 3 - Correctly computed fleet runner capacity metrics"

# Test 4: Validate wedged job detection (>20m)
echo "$OUTPUT" | grep -q '"wedged_jobs_count": 1'
echo "$OUTPUT" | grep -q 'Test Suite (2/12)'
echo "PASS: Test 4 - Correctly identified wedged shard exceeding threshold"

# Test 5: Validate pool distribution
echo "$OUTPUT" | grep -q '"portal-ci-linux": {'
echo "$OUTPUT" | grep -q '"covenant-clinic": {'
echo "PASS: Test 5 - Correctly partitioned runner pools"

# Test 6: Human-readable CLI formatting
CLI_OUTPUT=$("$BALANCER_SH" --mock-data "$MOCK_DATA")
echo "$CLI_OUTPUT" | grep -q "Jev CI Runner Health & Shard Balancer (Pattern 23):"
echo "$CLI_OUTPUT" | grep -q "Runner Pool Allocations:"
echo "$CLI_OUTPUT" | grep -q "Wedged Jobs Detected:"
echo "PASS: Test 6 - Verified human-readable summary output"

echo "=== All 6 fm-jev-runner-balancer tests passed successfully! ==="
