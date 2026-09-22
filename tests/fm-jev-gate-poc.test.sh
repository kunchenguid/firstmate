#!/usr/bin/env bash
# tests/fm-jev-gate-poc.test.sh - Offline behavioral tests for bin/fm-jev-gate-poc.sh.
#
# Covers:
#   1. Usage and help
#   2. Offline self-test mode (--self-test exits 0 and asserts all thresholds)
#   3. Live mode without API key fails closed without network call
#   4. Live mode with mock curl exercising approval, blocking, and review responses
#   5. Malformed API response handling (fail-closed)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-gate-poc.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-gate-poc)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# 1. Usage & Help
out=$("$TOOL" --help)
echo "$out" | grep -q -- "--self-test" || fail "expected --self-test in help output"
echo "$out" | grep -q -- "--live" || fail "expected --live in help output"
pass "help and usage flags documented"

# 2. Self-test offline mode
out=$("$TOOL" --self-test)
echo "$out" | grep -q "All 12 self-test assertions passed successfully" || fail "self-test failed or missed assertions"
pass "offline self-test mode passed"

# 3. Missing API key fails closed
unset OPENROUTER_API_KEY
FM_HOME="$TMP_ROOT/empty_home"
mkdir -p "$FM_HOME"
if FM_HOME="$FM_HOME" "$TOOL" --live >"$TMP_ROOT/missing_key.out" 2>&1; then
  fail "expected --live without key to fail"
else
  grep -q "OPENROUTER_API_KEY is not set" "$TMP_ROOT/missing_key.out" || fail "expected error message about OPENROUTER_API_KEY"
  pass "live mode without key fails closed"
fi

# 4. Mocked curl for offline scenario verification
cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
out_file=""
payload=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    out_file="$2"
    shift 2
  elif [ "$1" = "-d" ]; then
    payload="$2"
    shift 2
  else
    shift
  fi
done

# Inspect payload for fixture id
if echo "$payload" | grep -q "rm -rf /"; then
  cat > "$out_file" <<'JSON'
{"model":"typesafe/jev-1.13","answers":{"is_safe":{"type":"noul","noul":0.0}},"usage":{"cost":0.000015},"id":"mock1"}
JSON
elif echo "$payload" | grep -q "git status"; then
  cat > "$out_file" <<'JSON'
{"model":"typesafe/jev-1.13","answers":{"is_safe":{"type":"noul","noul":0.98}},"usage":{"cost":0.000015},"id":"mock2"}
JSON
else
  cat > "$out_file" <<'JSON'
{"model":"typesafe/jev-1.13","answers":{"is_safe":{"type":"noul","noul":0.50}},"usage":{"cost":0.000015},"id":"mock3"}
JSON
fi

printf '200:0.120'
EOF
chmod +x "$FAKEBIN/curl"

out=$(PATH="$FAKEBIN:$PATH" OPENROUTER_API_KEY="mock-test-key" "$TOOL" --live --scenario bash)
echo "$out" | grep -q "bash_safe_git_status.*approve" || fail "expected approve for git status"
echo "$out" | grep -q "bash_block_rm_rf_root.*block" || fail "expected block for rm -rf /"
pass "mocked live scenario verified approve, block, and review"

# 5. Malformed response fails closed
cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
out_file=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    out_file="$2"
    shift 2
  else
    shift
  fi
done
cat > "$out_file" <<'JSON'
{"model":"broken","invalid":true}
JSON
printf '200:0.050'
EOF
chmod +x "$FAKEBIN/curl"

if PATH="$FAKEBIN:$PATH" OPENROUTER_API_KEY="mock-test-key" "$TOOL" --live --scenario bash >"$TMP_ROOT/malformed.out" 2>&1; then
  fail "expected tool to fail on malformed API response"
else
  grep -q "ERROR" "$TMP_ROOT/malformed.out" || fail "expected ERROR reported for malformed fixtures"
  pass "malformed response fails closed as error"
fi
