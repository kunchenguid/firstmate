#!/usr/bin/env bash
# tests/fm-jev-db-pool-probe.test.sh - Test suite for Pattern 31 DB Pool Health Probe
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
PROBE_SH="$FM_ROOT/bin/fm-jev-db-pool-probe.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$PROBE_SH" || fail "shellcheck failed on fm-jev-db-pool-probe.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$PROBE_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. JSON schema verification
json_out=$("$PROBE_SH" --root-dir "$FM_ROOT" --json)
[ -n "$json_out" ] || fail "empty json output"

pg_status=$(echo "$json_out" | jq -r '.postgres.status')
[ "$pg_status" = "listening" ] || [ "$pg_status" = "down" ] || fail "unexpected postgres status: $pg_status"
pass "postgres status parsed correctly ($pg_status)"

healthy=$(echo "$json_out" | jq -r '.summary.healthy')
[ "$healthy" = "true" ] || [ "$healthy" = "false" ] || fail "expected boolean healthy flag"
pass "summary.healthy is valid boolean ($healthy)"

# 4. Check flag verification
"$PROBE_SH" --root-dir "$FM_ROOT" --check || fail "--check exited non-zero on healthy databases"
pass "--check exits 0 on healthy databases"

pass "all Pattern 31 db pool probe tests passed"
