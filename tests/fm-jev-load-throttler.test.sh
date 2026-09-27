#!/usr/bin/env bash
# tests/fm-jev-load-throttler.test.sh - Test suite for Pattern 30 Load Throttler
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
THROTTLER_SH="$FM_ROOT/bin/fm-jev-load-throttler.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$THROTTLER_SH" || fail "shellcheck failed on fm-jev-load-throttler.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$THROTTLER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. JSON schema verification
json_out=$("$THROTTLER_SH" --base-concurrency 10 --json)
[ -n "$json_out" ] || fail "empty json output"

status=$(echo "$json_out" | jq -r '.status')
[ "$status" = "CLEAR" ] || [ "$status" = "THROTTLED" ] || [ "$status" = "HIGH_PRESSURE" ] || fail "unexpected status: $status"
pass "status is valid enum ($status)"

cores=$(echo "$json_out" | jq -r '.load.cpu_cores')
[ "$cores" -gt 0 ] || fail "expected positive cpu core count"
pass "cpu cores detected correctly ($cores cores)"

rec_workers=$(echo "$json_out" | jq -r '.recommended_workers')
[ "$rec_workers" -ge 1 ] || fail "expected at least 1 recommended worker"
pass "recommended workers is positive ($rec_workers)"

# 4. --recommended-parallel flag test
parallel_out=$("$THROTTLER_SH" --base-concurrency 10 --recommended-parallel)
[ -n "$parallel_out" ] || fail "expected integer output from --recommended-parallel"
[[ "$parallel_out" =~ ^[0-9]+$ ]] || fail "expected numeric string, got $parallel_out"
pass "--recommended-parallel outputs valid integer ($parallel_out)"

pass "all Pattern 30 load throttler tests passed"
