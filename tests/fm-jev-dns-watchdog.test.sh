#!/usr/bin/env bash
# tests/fm-jev-dns-watchdog.test.sh - Test suite for Pattern 37 DNS Watchdog
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
WATCHDOG_SH="$FM_ROOT/bin/fm-jev-dns-watchdog.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$WATCHDOG_SH" || fail "shellcheck failed on fm-jev-dns-watchdog.sh"
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

canaries_count=$(echo "$json_out" | jq -r '.canary_resolution_probes | length')
[ "$canaries_count" -ge 2 ] || fail "expected at least 2 canary resolution probes"
pass "canary resolution probes present ($canaries_count probes)"

dead_ns=$(echo "$json_out" | jq -r '.dead_nameserver_count')
[ "$dead_ns" -ge 0 ] || fail "dead_nameserver_count must be non-negative"
pass "dead_nameserver_count valid ($dead_ns)"

# 4. Normal check mode
"$WATCHDOG_SH" --check || fail "expected check to pass on healthy host"
pass "--check passed cleanly"

# 5. Artificial low latency threshold test
low_lat_out=$("$WATCHDOG_SH" --max-latency 0.001 --json)
failed_canaries=$(echo "$low_lat_out" | jq -r '.failed_canaries_count')
[ "$failed_canaries" -gt 0 ] || fail "expected failed canaries with sub-microsecond threshold"
pass "low latency threshold correctly flags canaries ($failed_canaries flagged)"

pass "all Pattern 37 DNS watchdog tests passed"
