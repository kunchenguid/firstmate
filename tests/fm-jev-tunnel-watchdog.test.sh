#!/usr/bin/env bash
# tests/fm-jev-tunnel-watchdog.test.sh - Test suite for Pattern 35 Tunnel Watchdog
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
WATCHDOG_SH="$FM_ROOT/bin/fm-jev-tunnel-watchdog.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$WATCHDOG_SH" || fail "shellcheck failed on fm-jev-tunnel-watchdog.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$WATCHDOG_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. JSON schema verification
json_out=$("$WATCHDOG_SH" --json)
[ -n "$json_out" ] || fail "empty json output"

healthy=$(echo "$json_out" | jq -r '.healthy')
[ "$healthy" = "true" ] || [ "$healthy" = "false" ] || fail "unexpected healthy boolean: $healthy"
pass "healthy field is valid boolean ($healthy)"

procs_count=$(echo "$json_out" | jq -r '.audited_processes_count')
[ "$procs_count" -ge 0 ] || fail "audited_processes_count must be non-negative"
pass "audited_processes_count valid ($procs_count)"

conns_count=$(echo "$json_out" | jq -r '.active_ssh_connections_count')
[ "$conns_count" -ge 0 ] || fail "active_ssh_connections_count must be non-negative"
pass "active_ssh_connections_count valid ($conns_count)"

# 4. Normal check mode
"$WATCHDOG_SH" --check || fail "expected check to pass on healthy host"
pass "--check passed cleanly"

# 5. Low threshold verification with safe mock
low_age_out=$("$WATCHDOG_SH" --max-age 999999 --json)
low_stale=$(echo "$low_age_out" | jq -r '.flagged_stale_count')
[ "$low_stale" -eq 0 ] || fail "expected 0 stale processes with large max-age"
pass "large max-age produces 0 stale processes"

pass "all Pattern 35 tunnel watchdog tests passed"
