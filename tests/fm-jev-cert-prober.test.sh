#!/usr/bin/env bash
# tests/fm-jev-cert-prober.test.sh - Test suite for Pattern 38 TLS Cert Prober
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
PROBER_SH="$FM_ROOT/bin/fm-jev-cert-prober.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$PROBER_SH" || fail "shellcheck failed on fm-jev-cert-prober.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$PROBER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. JSON schema verification
json_out=$("$PROBER_SH" --json)
[ -n "$json_out" ] || fail "empty json output"

healthy=$(echo "$json_out" | jq -r '.healthy')
[ "$healthy" = "true" ] || [ "$healthy" = "false" ] || fail "unexpected healthy boolean: $healthy"
pass "healthy field is valid boolean ($healthy)"

targets_count=$(echo "$json_out" | jq -r '.audited_targets_count')
[ "$targets_count" -ge 2 ] || fail "expected at least 2 audited targets"
pass "audited_targets_count is valid ($targets_count)"

# 4. Normal check mode
"$PROBER_SH" --check || fail "expected check to pass on healthy endpoints"
pass "--check passed cleanly"

# 5. Artificial high min-days threshold test
high_days_out=$("$PROBER_SH" --min-days 99999 --json)
flagged_count=$(echo "$high_days_out" | jq -r '.flagged_targets_count')
[ "$flagged_count" -gt 0 ] || fail "expected flagged certs with artificially high min-days"
pass "high min-days threshold correctly flags expiring certs ($flagged_count flagged)"

pass "all Pattern 38 TLS cert prober tests passed"
