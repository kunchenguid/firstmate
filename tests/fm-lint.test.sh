#!/usr/bin/env bash
# Contract tests for deterministic ShellCheck parity between CI and no-mistakes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
test_owner_and_gate_wiring() {
  local tmp fakebin log output rc
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable"
  tmp=$(fm_test_tmproot fm-lint-owner)
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = '--version' ]; then
  printf '%s\n' 'version: 0.11.0'
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_SHELLCHECK_LOG"
SH
  chmod +x "$fakebin/shellcheck"
  output=$(PATH="$fakebin:$PATH" FM_TEST_SHELLCHECK_LOG="$log" \
    "$LINT" bin/fm-lint.sh tests/fm-lint.test.sh 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 0 ] || fail "lint owner rejected a matching ShellCheck: $output"
  assert_grep '--norc -x -P SCRIPTDIR -S warning' "$log" \
    "lint owner did not pass canonical ShellCheck options"
  assert_grep 'bin/fm-lint.sh tests/fm-lint.test.sh' "$log" \
    "lint owner did not pass selected files"
  pass "lint owner executes the pinned ShellCheck interface"
}

test_version_pin_and_rejection() {
  local required tmp fakebin output rc
  required=$("$LINT" --required-version) || fail "lint owner cannot report its version"
  [ "$required" = '0.11.0' ] || fail "unexpected ShellCheck pin: $required"
  tmp=$(fm_test_tmproot fm-lint-version)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = '--version' ]; then
  printf '%s\n' 'version: 0.9.0'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  output=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "lint owner accepted an unpinned ShellCheck"
  assert_contains "$output" "$required" "version error omitted the required ShellCheck pin"
  pass "lint owner rejects version drift"
}

test_owner_and_gate_wiring
test_version_pin_and_rejection
