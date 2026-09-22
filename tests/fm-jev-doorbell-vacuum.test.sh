#!/usr/bin/env bash
# tests/fm-jev-doorbell-vacuum.test.sh - Regression test suite for Pattern 18
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VACUUM_ENGINE="${FM_ROOT}/bin/fm-jev-doorbell-vacuum.py"
VACUUM_WRAPPER="${FM_ROOT}/bin/fm-jev-doorbell-vacuum.sh"

echo "=== Running fm-jev-doorbell-vacuum test suite ==="

# Test 1: Python syntax compilation
python3 -m py_compile "${VACUUM_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${VACUUM_WRAPPER}"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Functional vacuum test with mock state directory
TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT

MOCK_STATE="${TEST_TMP}/state"
mkdir -p "${MOCK_STATE}/seat-a.inbox/handled"
mkdir -p "${MOCK_STATE}/seat-b.inbox/handled"

# Populate seat-a:
# 1 stale handled msg (mtime set to 48 hours ago)
echo "old steer" > "${MOCK_STATE}/seat-a.inbox/handled/001.msg"
python3 -c "import os, time; t = time.time() - 48*3600; os.utime('${MOCK_STATE}/seat-a.inbox/handled/001.msg', (t, t))"

# 1 fresh handled msg (mtime set to 1 hour ago)
echo "recent steer" > "${MOCK_STATE}/seat-a.inbox/handled/002.msg"
python3 -c "import os, time; t = time.time() - 3600; os.utime('${MOCK_STATE}/seat-a.inbox/handled/002.msg', (t, t))"

# Stale .ring-state on idle seat-a
echo "001.msg 1 100" > "${MOCK_STATE}/seat-a.inbox/.ring-state"
python3 -c "import os, time; t = time.time() - 48*3600; os.utime('${MOCK_STATE}/seat-a.inbox/.ring-state', (t, t))"

# Populate seat-b (active seat):
# 1 unhandled pending message
echo "urgent steer" > "${MOCK_STATE}/seat-b.inbox/001.msg"
# Stale .ring-state, BUT pending unhandled message exists -> MUST BE PRESERVED
echo "001.msg 1 100" > "${MOCK_STATE}/seat-b.inbox/.ring-state"
python3 -c "import os, time; t = time.time() - 48*3600; os.utime('${MOCK_STATE}/seat-b.inbox/.ring-state', (t, t))"

# Test 3: Dry run does not delete anything
OUTPUT_DRY=$("${VACUUM_WRAPPER}" --state-dir "${MOCK_STATE}" --dry-run)
echo "${OUTPUT_DRY}" | grep -q "\[DRY_RUN\]"
test -f "${MOCK_STATE}/seat-a.inbox/handled/001.msg"
test -f "${MOCK_STATE}/seat-a.inbox/handled/002.msg"
test -f "${MOCK_STATE}/seat-a.inbox/.ring-state"
echo "PASS: Test 3 - Dry-run mode preserves all files"

# Test 4: Live vacuum prunes stale handled msg & idle ring-state, preserves fresh msg & active ring-state
OUTPUT_LIVE=$("${VACUUM_WRAPPER}" --state-dir "${MOCK_STATE}")
echo "${OUTPUT_LIVE}" | grep -q "\[VACUUM_APPLIED\]"
# seat-a 001.msg should be deleted
if [ -f "${MOCK_STATE}/seat-a.inbox/handled/001.msg" ]; then
  echo "FAIL: seat-a 001.msg was not pruned" >&2
  exit 1
fi
# seat-a 002.msg (fresh) MUST remain
if [ ! -f "${MOCK_STATE}/seat-a.inbox/handled/002.msg" ]; then
  echo "FAIL: seat-a 002.msg was incorrectly pruned" >&2
  exit 1
fi
# seat-a .ring-state should be deleted (stale & no pending)
if [ -f "${MOCK_STATE}/seat-a.inbox/.ring-state" ]; then
  echo "FAIL: seat-a .ring-state was not pruned" >&2
  exit 1
fi
# seat-b unhandled 001.msg MUST remain
if [ ! -f "${MOCK_STATE}/seat-b.inbox/001.msg" ]; then
  echo "FAIL: seat-b unhandled 001.msg was deleted!" >&2
  exit 1
fi
# seat-b .ring-state MUST remain because seat-b has pending unhandled message
if [ ! -f "${MOCK_STATE}/seat-b.inbox/.ring-state" ]; then
  echo "FAIL: seat-b .ring-state was deleted despite pending unhandled message!" >&2
  exit 1
fi
echo "PASS: Test 4 - Live vacuum precisely pruned stale files while protecting active messages"

# Test 5: JSON output validity
JSON_OUT=$("${VACUUM_WRAPPER}" --state-dir "${MOCK_STATE}" --json)
python3 -c "import json; d = json.loads('''${JSON_OUT}'''); assert 'inboxes_scanned' in d; assert d['inboxes_scanned'] == 2"
echo "PASS: Test 5 - JSON output format and metadata validated"

echo "=== All 5 fm-jev-doorbell-vacuum tests passed successfully! ==="
