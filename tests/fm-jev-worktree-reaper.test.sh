#!/usr/bin/env bash
# tests/fm-jev-worktree-reaper.test.sh - Regression test suite for Pattern 19
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAPER_ENGINE="${FM_ROOT}/bin/fm-jev-worktree-reaper.py"
REAPER_WRAPPER="${FM_ROOT}/bin/fm-jev-worktree-reaper.sh"

echo "=== Running fm-jev-worktree-reaper test suite ==="

# Test 1: Python syntax compilation
python3 -m py_compile "${REAPER_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${REAPER_WRAPPER}"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Setup temporary test repository
TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT

REPO="${TEST_TMP}/repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -b main
git -C "${REPO}" config user.name "Test User"
git -C "${REPO}" config user.email "test@example.com"
echo "init" > "${REPO}/README.md"
git -C "${REPO}" add README.md
git -C "${REPO}" commit -m "init"

# Create worktree 1: merged worktree
git -C "${REPO}" branch merged-feature
WT1="${TEST_TMP}/wt-merged"
git -C "${REPO}" worktree add "${WT1}" merged-feature
echo "feature" > "${WT1}/feature.txt"
git -C "${WT1}" add feature.txt
git -C "${WT1}" commit -m "feature commit"
git -C "${REPO}" merge --no-ff merged-feature -m "merge feature"

# Create worktree 2: dirty worktree
git -C "${REPO}" branch dirty-feature
WT2="${TEST_TMP}/wt-dirty"
git -C "${REPO}" worktree add "${WT2}" dirty-feature
echo "uncommitted change" >> "${WT2}/dirty.txt"

# Test 3: Dry run verifies identification without removing
DRY_OUTPUT=$("${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main --dry-run)
echo "${DRY_OUTPUT}" | grep -q "\[DRY_RUN\]"
test -d "${WT1}"
test -d "${WT2}"
echo "PASS: Test 3 - Dry run mode preserves all worktrees"

# Test 4: Live reap prunes merged worktree WT1 and strictly protects dirty WT2
LIVE_OUTPUT=$("${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${LIVE_OUTPUT}" | grep -q "\[REAPER_APPLIED\]"
if [ -d "${WT1}" ]; then
  echo "FAIL: merged worktree WT1 was not removed" >&2
  exit 1
fi
if [ ! -d "${WT2}" ]; then
  echo "FAIL: dirty worktree WT2 was incorrectly removed!" >&2
  exit 1
fi
echo "PASS: Test 4 - Live reap removed merged worktree and preserved dirty worktree"

# Test 5: JSON output telemetry
JSON_OUTPUT=$("${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main --json)
python3 -c "import json; d = json.loads('''${JSON_OUTPUT}'''); assert 'dirty_preserved' in d; assert d['dirty_preserved'] == 1"
echo "PASS: Test 5 - JSON telemetry output validated"

echo "=== All 5 fm-jev-worktree-reaper tests passed successfully! ==="

python3 "$(dirname "${BASH_SOURCE[0]}")/jev-safety-fixtures.py" worktree-reaper
