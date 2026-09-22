#!/usr/bin/env bash
# tests/fm-jev-quota-prober.test.sh - Regression test suite for Pattern 9 Quota Prober.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBER="$FM_ROOT/bin/fm-jev-quota-prober.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

printf '1. Verify help flag...\n'
"$PROBER" --help >/dev/null 2>&1 || fail "prober --help failed"
ok "help flag works"

printf '2. Verify --check-all output...\n'
output=$("$PROBER" --check-all) || fail "check-all failed"
printf '%s\n' "$output" | grep -q "Fleet Pre-Flight Harness Runway" || fail "missing header in check-all"
printf '%s\n' "$output" | grep -q "cursor-grok-4.6-high" || fail "missing grok in check-all"
ok "check-all verifies runway and diversions"

printf '3. Verify --json output format...\n'
json_out=$("$PROBER" --check-all --json) || fail "--check-all --json failed"
echo "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert isinstance(data, list)
assert len(data) >= 3
assert any(d["harness"] == "cursor" for d in data)
' || fail "malformed json output"
ok "json output format verified"

printf '4. Verify --auto-divert flag on exhausted harness...\n'
divert_out=$("$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert) || fail "auto-divert failed"
echo "$divert_out" | grep -q "harness=cursor model=cursor-grok-4.6-high" || fail "failed to divert dry zai bundle"
ok "auto-divert safely redirects to cursor grok"

printf 'ok - all fm-jev-quota-prober tests passed\n'
