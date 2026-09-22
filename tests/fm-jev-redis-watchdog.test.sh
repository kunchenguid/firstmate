#!/usr/bin/env bash
# tests/fm-jev-redis-watchdog.test.sh - Test suite for Pattern 29 Redis/DB Leaked Connection Watchdog
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
WATCHDOG_SH="$FM_ROOT/bin/fm-jev-redis-watchdog.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$WATCHDOG_SH" || fail "shellcheck failed on fm-jev-redis-watchdog.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$WATCHDOG_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. JSON output schema verification
json_out=$("$WATCHDOG_SH" --ports "5432,6379" --json)
[ -n "$json_out" ] || fail "empty json output"

total_conns=$(echo "$json_out" | jq -r '.summary.total_connections')
[ -n "$total_conns" ] || fail "missing total_connections in json"
pass "json output schema contains summary.total_connections ($total_conns)"

health_status=$(echo "$json_out" | jq -r '.summary.healthy')
[ "$health_status" = "true" ] || [ "$health_status" = "false" ] || fail "unexpected health_status: $health_status"
pass "json output schema contains valid boolean healthy ($health_status)"

# 4. Custom port filtering verification
filtered_out=$("$WATCHDOG_SH" --ports "5432" --json)
has_5432=$(echo "$filtered_out" | jq -r '.ports["5432"]')
[ "$has_5432" != "null" ] || fail "expected port 5432 in ports object"
has_6379=$(echo "$filtered_out" | jq -r '.ports["6379"]')
[ "$has_6379" = "null" ] || fail "expected port 6379 to be excluded"
pass "port filtering correctly isolates target ports"

pass "all Pattern 29 redis/db watchdog tests passed"
