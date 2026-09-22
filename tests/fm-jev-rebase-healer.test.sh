#!/usr/bin/env bash
# tests/fm-jev-rebase-healer.test.sh - Test suite for Pattern 33 Git Lock Auto-Healer
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
HEALER_SH="$FM_ROOT/bin/fm-jev-rebase-healer.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-healer-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$HEALER_SH" || fail "shellcheck failed on fm-jev-rebase-healer.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$HEALER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Create mock git repo with a simulated stale index.lock
MOCK_REPO="$TDIR/mock-repo"
mkdir -p "$MOCK_REPO/.git"
LOCK_FILE="$MOCK_REPO/.git/index.lock"
touch "$LOCK_FILE"
# Set mtime back by 300 seconds
python3 -c "import os, time; t = time.time() - 300; os.utime('$LOCK_FILE', (t, t))"

# Audit in dry-run mode
dry_run_out=$("$HEALER_SH" --dirs "$TDIR" --stale-age-sec 60 --json)
[ -n "$dry_run_out" ] || fail "empty dry-run output"

stale_detected=$(echo "$dry_run_out" | jq -r '.summary.repos_with_locks_or_issues')
[ "$stale_detected" -eq 1 ] || fail "expected 1 repo with issue, got $stale_detected"
pass "detected stale index.lock in dry-run mode"

[ -f "$LOCK_FILE" ] || fail "dry-run mode erroneously deleted lock file!"
pass "dry-run mode preserved lock file"

# Audit in heal mode
heal_out=$("$HEALER_SH" --dirs "$TDIR" --stale-age-sec 60 --heal --json)
healed_count=$(echo "$heal_out" | jq -r '.summary.healed_count')
[ "$healed_count" -eq 1 ] || fail "expected healed_count=1, got $healed_count"
pass "healed stale lock file ($healed_count healed)"

[ ! -f "$LOCK_FILE" ] || fail "heal mode failed to remove lock file"
pass "stale lock file safely removed in heal mode"

pass "all Pattern 33 git lock healer tests passed"

python3 "$(dirname "${BASH_SOURCE[0]}")/jev-safety-fixtures.py" rebase-healer
