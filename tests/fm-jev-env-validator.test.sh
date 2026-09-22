#!/usr/bin/env bash
# tests/fm-jev-env-validator.test.sh - Test suite for Pattern 28 Environment Validator
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
VALIDATOR_SH="$FM_ROOT/bin/fm-jev-env-validator.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-env-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$VALIDATOR_SH" || fail "shellcheck failed on fm-jev-env-validator.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$VALIDATOR_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Test with mock variable and mock path
export TEST_MOCK_VAR="present_secret_value_not_to_be_printed"
MOCK_FILE="$TDIR/mock_cred.key"
echo "secret_bytes" > "$MOCK_FILE"

json_out=$("$VALIDATOR_SH" --vars "TEST_MOCK_VAR,NONEXISTENT_VAR_XYZ" --paths "$MOCK_FILE,$TDIR/nonexistent_file" --json)

var_status=$(echo "$json_out" | jq -r '.environment.TEST_MOCK_VAR.status')
[ "$var_status" = "present" ] || fail "expected TEST_MOCK_VAR=present, got $var_status"

missing_var=$(echo "$json_out" | jq -r '.environment.NONEXISTENT_VAR_XYZ.status')
[ "$missing_var" = "missing" ] || fail "expected NONEXISTENT_VAR_XYZ=missing, got $missing_var"

path_status=$(echo "$json_out" | jq -r --arg p "$MOCK_FILE" '.credentials[$p].status')
[ "$path_status" = "available" ] || fail "expected mock file=available, got $path_status"

missing_path=$(echo "$json_out" | jq -r --arg p "$TDIR/nonexistent_file" '.credentials[$p].status')
[ "$missing_path" = "missing" ] || fail "expected nonexistent_file=missing, got $missing_path"

# 4. Invariant: Ensure the actual secret string is never leaked in JSON
if echo "$json_out" | grep -q "present_secret_value"; then
  fail "SECURITY INVARIANT VIOLATION: Secret value found in JSON telemetry!"
fi
pass "zero secret value egress invariant holds"

json_out=$(FM_HOME="$TDIR" HOME="$TDIR" USER=test SHELL=/bin/bash TEST_EMPTY=' ' "$VALIDATOR_SH" --vars TEST_EMPTY --json)
echo "$json_out" | jq -e '.environment.TEST_EMPTY.status == "empty" and .summary.missing_vars == 0 and .summary.empty_vars == 1 and .summary.healthy == false' >/dev/null || fail "empty variable reported healthy"

pass "all Pattern 28 environment validator tests passed"
