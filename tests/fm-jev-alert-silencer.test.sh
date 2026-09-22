#!/usr/bin/env bash
# tests/fm-jev-alert-silencer.test.sh - Regression tests for Pattern 43
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-alert-silencer.sh"
TEST_STATE="/tmp/test-alert-silencer-$$.json"
trap 'rm -f "$TEST_STATE" "$TEST_STATE.tmp."*' EXIT

echo "Running Pattern 43 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 3. JSON schema validation on audit
json_out="$("$GUARD_SH" --audit --state-file "$TEST_STATE" --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'summary' in data
assert 'top_active_signatures' in data
assert isinstance(data['summary']['healthy'], bool)
assert data['summary']['total_processed'] == 0
"
echo "ok - json audit schema valid"

# 4. Check mode passes on healthy state
"$GUARD_SH" --audit --state-file "$TEST_STATE" --check
echo "ok - --check passed cleanly"

# 5. First alert delivers
out1=$("$GUARD_SH" --source worker1 --category db --message "DB timeout on pool" --state-file "$TEST_STATE" --max-burst 1 --json)
python3 -c "import json; d=json.loads('''$out1'''); assert d['action'] == 'DELIVER'"
echo "ok - first alert delivered"

# 6. Second alert with same normalized error is suppressed
out2=$("$GUARD_SH" --source worker1 --category db --message "DB timeout on pool" --state-file "$TEST_STATE" --max-burst 1 --json)
python3 -c "import json; d=json.loads('''$out2'''); assert d['action'] == 'SUPPRESS'"
echo "ok - duplicate alert suppressed"

# 7. Check mode returns exit code 2 when suppressed alert occurs
if "$GUARD_SH" --source worker1 --category db --message "DB timeout on pool" --state-file "$TEST_STATE" --max-burst 1 --check >/dev/null 2>&1; then
    echo "FAILED: check mode should return non-zero on suppressed alert"
    exit 1
else
    echo "ok - check mode returns non-zero exit on suppressed alert"
fi

echo "ok - all Pattern 43 alert silencer tests passed"
