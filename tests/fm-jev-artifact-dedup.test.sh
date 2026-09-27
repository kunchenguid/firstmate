#!/usr/bin/env bash
# tests/fm-jev-artifact-dedup.test.sh - Regression test suite for Pattern 21
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEDUP_ENGINE="${FM_ROOT}/bin/fm-jev-artifact-dedup.py"
DEDUP_WRAPPER="${FM_ROOT}/bin/fm-jev-artifact-dedup.sh"

echo "=== Running fm-jev-artifact-dedup test suite ==="

# Test 1: Python syntax compilation
python3 -m py_compile "${DEDUP_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${DEDUP_WRAPPER}"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Setup temporary test directory
TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT

DIR1="${TEST_TMP}/worktree1/site/public/scores"
DIR2="${TEST_TMP}/worktree2/site/public/scores"
mkdir -p "${DIR1}" "${DIR2}"

# Create identical 4KB SVG artifact in both dirs
SAMPLE_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg width=\"100\" height=\"100\">$(printf '<!-- padding %0200d -->\n' {1..30})</svg>"
echo "${SAMPLE_CONTENT}" > "${DIR1}/page1.svg"
echo "${SAMPLE_CONTENT}" > "${DIR2}/page1.svg"

# Verify initially separate inodes
INODE1=$(stat -c '%i' "${DIR1}/page1.svg")
INODE2=$(stat -c '%i' "${DIR2}/page1.svg")
if [ "${INODE1}" -eq "${INODE2}" ]; then
  echo "FAIL: Test files already share same inode" >&2
  exit 1
fi

# Test 3: Dry-run identifies duplicate without linking
DRY_OUT=$("${DEDUP_WRAPPER}" --roots "${TEST_TMP}" --min-size 100 --dry-run)
echo "${DRY_OUT}" | grep -q "\[DRY_RUN\]"
echo "${DRY_OUT}" | grep -q "Duplicate Instances: 1"
INODE2_AFTER_DRY=$(stat -c '%i' "${DIR2}/page1.svg")
if [ "${INODE2}" -ne "${INODE2_AFTER_DRY}" ]; then
  echo "FAIL: Dry run modified inode" >&2
  exit 1
fi
echo "PASS: Test 3 - Dry run correctly identifies duplicate and preserves files"

# Test 4: Live deduplication preserves independent writes
LIVE_OUT=$("${DEDUP_WRAPPER}" --roots "${TEST_TMP}" --min-size 100)
echo "${LIVE_OUT}" | grep -q "\[APPLIED\]"
INODE1_FINAL=$(stat -c '%i' "${DIR1}/page1.svg")
INODE2_FINAL=$(stat -c '%i' "${DIR2}/page1.svg")
if [ "${INODE1_FINAL}" -eq "${INODE2_FINAL}" ]; then
  echo "FAIL: Files share writable storage after live deduplication" >&2
  exit 1
fi
# Content verify
cmp "${DIR1}/page1.svg" "${DIR2}/page1.svg"
printf 'changed' > "${DIR2}/page1.svg"
if cmp -s "${DIR1}/page1.svg" "${DIR2}/page1.svg"; then
  echo "FAIL: modifying one artifact changed the other" >&2
  exit 1
fi
echo "PASS: independent writes remain isolated"

# Test 5: JSON output telemetry schema
JSON_OUT=$("${DEDUP_WRAPPER}" --roots "${TEST_TMP}" --min-size 100 --dry-run --json)
python3 -c "
import json
data = json.loads('''${JSON_OUT}''')
assert 'files_scanned' in data, 'files_scanned missing'
assert 'bytes_reclaimed' in data, 'bytes_reclaimed missing'
assert 'unique_content_hashes' in data, 'unique_content_hashes missing'
assert data['dry_run'] == True, 'dry_run must be True'
"
echo "PASS: Test 5 - JSON telemetry schema validated"

echo "=== All 5 fm-jev-artifact-dedup tests passed successfully! ==="
