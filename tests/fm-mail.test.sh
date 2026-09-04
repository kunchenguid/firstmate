#!/usr/bin/env bash
# Behavior tests for bin/fm-mail.sh.
#
# fm-mail.sh is a network mail client, so these tests exercise only the paths
# that need no real IMAP/SMTP connection: the config-validation dry run, the
# read-only `status` surface, and the CLI usage/help plumbing. All of them go
# through the executable public interface of bin/fm-mail.sh and never assert
# internal source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAIL="$ROOT/bin/fm-mail.sh"
TMP_ROOT=$(fm_test_tmproot fm-mail)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"

test_missing_secret_fails_cleanly() {
  local out rc
  env -u FM_MAIL_USER -u FM_MAIL_PASS -u FM_IMAP_HOST -u FM_SMTP_HOST \
    FM_HOME="$HOME_DIR" "$MAIL" status >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  expect_code 1 "$rc" "status without configuration must fail"
  out=$(cat "$TMP_ROOT/err")
  assert_contains "$out" "FM_MAIL_USER" "missing-config error names the missing variable"
  assert_contains "$out" "FM_MAIL_*" "missing-config error names the configuration family"
  assert_not_contains "$out" "test-pass" "missing-config error never leaks a secret"
  pass "fm-mail: missing required configuration fails cleanly naming the variable"
}

test_status_without_network() {
  local out rc
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" status 2>&1)
  rc=$?
  expect_code 0 "$rc" "status with configuration must succeed without network"
  assert_contains "$out" "mail account: test@example.com" "status prints the configured account"
  assert_contains "$out" "imap.test.invalid:993" "status prints the configured imap endpoint"
  assert_contains "$out" "smtp.test.invalid:465" "status prints the configured smtp endpoint"
  assert_contains "$out" "cursor:" "status prints the cursor line"
  pass "fm-mail: status succeeds without network and prints configuration"
}

test_help_plumbing() {
  local out rc
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "read" "--help lists the read subcommand"
  assert_contains "$out" "send" "--help lists the send subcommand"
  assert_contains "$out" "poll" "--help lists the poll subcommand"
  assert_contains "$out" "status" "--help lists the status subcommand"
  pass "fm-mail: --help prints usage for every subcommand"
}

test_unknown_subcommand_prints_usage() {
  local out rc
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" bogus 2>&1)
  rc=$?
  expect_code 1 "$rc" "unknown subcommand must exit 1"
  assert_contains "$out" "read" "unknown subcommand prints usage"
  assert_contains "$out" "status" "unknown subcommand prints usage"
  pass "fm-mail: unknown subcommand prints usage and exits non-zero"
}

test_no_secret_leaked_to_status() {
  local out
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" status 2>&1)
  assert_not_contains "$out" "test-pass" "status must never print the password"
  pass "fm-mail: status never prints the password"
}

test_send_passes_body() {
  local fakebin body_file stdin_file
  fakebin=$(fm_fakebin fm-mail)
  stdin_file="$TMP_ROOT/stdin_capture.txt"

  # Fake python3 that reads stdin (the body pipe) and writes it to a file.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
cat > "${FM_MAIL_TEST_STDIN_FILE:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/python3"

  body_file="$TMP_ROOT/body.txt"
  printf '%s' "hello world" > "$body_file"
  export FM_MAIL_TEST_STDIN_FILE="$stdin_file"
  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=h FM_SMTP_HOST=h \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" send to@example.com subj "hello world" 2>&1) || rc=$?
  expect_code 0 "$rc" "send with body must succeed"
  local captured
  captured=$(cat "$stdin_file" 2>/dev/null || echo "")
  assert_contains "$captured" "hello world" "send passes body through stdin to python3"
  pass "fm-mail: send passes body not empty through stdin"
}

test_poll_error_propagates() {
  local fakebin
  fakebin=$(fm_fakebin fm-mail)

  # Fake python3 that exits with an error (simulating IMAP failure).
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
echo "fm-mail poll error: connection refused" >&2
exit 1
SH
  chmod +x "$fakebin/python3"

  local out rc=0
  out=$(env -u FM_MAIL_USER -u FM_MAIL_PASS -u FM_IMAP_HOST -u FM_SMTP_HOST \
    FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must propagate python3 errors"
  assert_contains "$out" "connection refused" "poll error message is visible"
  pass "fm-mail: poll propagates errors instead of swallowing them"
}

test_missing_secret_fails_cleanly
test_status_without_network
test_help_plumbing
test_unknown_subcommand_prints_usage
test_no_secret_leaked_to_status
test_send_passes_body
test_poll_error_propagates
