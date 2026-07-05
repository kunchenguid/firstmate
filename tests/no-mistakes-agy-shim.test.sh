#!/usr/bin/env bash
# no-mistakes-agy-shim times out hung headless agy -p calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/no-mistakes-agy-shim"
TMP_ROOT=$(fm_test_tmproot no-mistakes-agy-shim)
fakebin=$(fm_fakebin "$TMP_ROOT/fake")

cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
sleep 30
printf 'should not finish\n'
SH
chmod +x "$fakebin/agy"

if ! command -v timeout >/dev/null 2>&1; then
  pass "skip timeout test: timeout(1) not on PATH"
else
  out=$(FM_AGY_SHIM_TIMEOUT=1 NO_MISTAKES_AGY_BIN="$fakebin/agy" PATH="$fakebin:$PATH" \
    "$SHIM" -p 'say hi' 2>&1) || status=$?
  status=${status:-0}
  expect_code 124 "$status" "shim should exit 124 on agy timeout"
  assert_contains "$out" 'timed out' "shim timeout stderr missing"
  pass "no-mistakes-agy-shim honors FM_AGY_SHIM_TIMEOUT"
fi

# Test robust JSON extraction with braces outside
cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
echo "Some {unrelated} braces here and there."
echo "Here is the valid JSON:"
echo '```json'
echo '{"summary": "success", "nested": {"key": "val {with brace}"}}'
echo '```'
echo "And some trailing {braces} too."
SH
chmod +x "$fakebin/agy"

out=$(NO_MISTAKES_AGY_BIN="$fakebin/agy" PATH="$fakebin:$PATH" \
  "$SHIM" --json-schema '{"type": "object"}' -p 'say hi')
status=$?
expect_code 0 "$status" "shim should succeed with valid JSON extract"
assert_contains "$out" '"structured_output": {"summary": "success", "nested": {"key": "val {with brace}"}}' "JSON structured output missing or incorrect"
pass "no-mistakes-agy-shim extracts JSON robustly with external braces"

# Test error stream redirection: JSON error event is on stdout, error message on stderr
cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
echo "some stderr logs" >&2
exit 5
SH
chmod +x "$fakebin/agy"

stdout_file="$TMP_ROOT/stdout.log"
stderr_file="$TMP_ROOT/stderr.log"

NO_MISTAKES_AGY_BIN="$fakebin/agy" PATH="$fakebin:$PATH" \
  "$SHIM" -p 'say hi' >"$stdout_file" 2>"$stderr_file" || status=$?
status=${status:-0}
expect_code 5 "$status" "shim should exit with agy exit code"

out_stdout=$(cat "$stdout_file")
out_stderr=$(cat "$stderr_file")

assert_contains "$out_stdout" '{"type":"result","subtype":"error","is_error":true}' "JSON error event should be on stdout"
assert_contains "$out_stderr" "agy exited: some stderr logs" "error message should be on stderr"
pass "no-mistakes-agy-shim outputs JSON error event to stdout and log message to stderr"

# Test schema extraction failure
cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
echo "no json here"
SH
chmod +x "$fakebin/agy"

stdout_file="$TMP_ROOT/stdout.log"
stderr_file="$TMP_ROOT/stderr.log"

status=0
NO_MISTAKES_AGY_BIN="$fakebin/agy" PATH="$fakebin:$PATH" \
  "$SHIM" --json-schema '{"type": "object"}' -p 'say hi' >"$stdout_file" 2>"$stderr_file" || status=$?
expect_code 1 "$status" "shim should exit 1 on schema extraction failure"

out_stdout=$(cat "$stdout_file")
assert_contains "$out_stdout" '"content": [{"type": "text", "text": "no json here\n"}]' "assistant message on stdout missing"
assert_contains "$out_stdout" '{"type": "result", "subtype": "error", "is_error": true}' "JSON error event on stdout missing"
pass "no-mistakes-agy-shim outputs JSON error event and exits 1 when JSON extraction fails"

# Test --permission-mode option parsing
cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
echo "dummy output"
SH
chmod +x "$fakebin/agy"

out=$(NO_MISTAKES_AGY_BIN="$fakebin/agy" PATH="$fakebin:$PATH" \
  "$SHIM" --permission-mode yolo -p 'correct prompt')
assert_contains "$out" '"text": "dummy output\n"' "permission mode parsing failed"
pass "no-mistakes-agy-shim parses --permission-mode option and retains correct prompt"