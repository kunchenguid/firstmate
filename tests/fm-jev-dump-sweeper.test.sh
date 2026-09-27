#!/usr/bin/env bash
# tests/fm-jev-dump-sweeper.test.sh - Test suite for Pattern 34 Dump Sweeper
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
SWEEPER_SH="$FM_ROOT/bin/fm-jev-dump-sweeper.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-dump-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$SWEEPER_SH" || fail "shellcheck failed on fm-jev-dump-sweeper.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$SWEEPER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Create mock core dump and mock oversized log in temp dir
MOCK_CORE="$TDIR/core.12345"
echo "mock_core_dump_bytes" > "$MOCK_CORE"

MOCK_LOG="$TDIR/worker_error.log"
# Create ~2MB file and set threshold to 1MB
dd if=/dev/zero of="$MOCK_LOG" bs=1M count=2 status=none

# Test dry-run detection
json_dry=$("$SWEEPER_SH" --dirs "$TDIR" --max-log-size-mb 1.0 --json)
[ -n "$json_dry" ] || fail "empty json output"

candidates=$(echo "$json_dry" | jq -r '.summary.candidates_found')
[ "$candidates" -eq 2 ] || fail "expected 2 candidates, got $candidates"
pass "detected mock core dump and oversized log ($candidates candidates)"

[ -f "$MOCK_CORE" ] || fail "dry-run erroneously deleted core dump!"
[ -f "$MOCK_LOG" ] || fail "dry-run erroneously deleted log file!"
pass "dry-run mode strictly preserved files"

# Test sweep mode
json_sweep=$("$SWEEPER_SH" --dirs "$TDIR" --max-log-size-mb 1.0 --sweep --json)
reclaimed=$(echo "$json_sweep" | jq -r '.summary.reclaimed_count')
[ "$reclaimed" -eq 2 ] || fail "expected 2 reclaimed, got $reclaimed"
pass "sweep mode safely reclaimed candidates ($reclaimed files)"

[ ! -f "$MOCK_CORE" ] || fail "core dump still exists after sweep"
[ ! -f "$MOCK_LOG" ] || fail "log file still exists after sweep"
pass "candidates safely unlinked"

pass "all Pattern 34 dump sweeper tests passed"
