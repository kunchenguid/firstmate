#!/usr/bin/env bash
# Behavior tests for bin/fm-ps-portable.sh - the portable process-introspection
# shim that keeps the harness-ancestry walk (fm-lock.sh, fm-harness.sh) and the
# pid fingerprint (fm-wake-lib.sh) working on platforms whose `ps` lacks the
# `-o` flag (MSYS2 / Git Bash on Windows), with byte-identical behavior on
# macOS/Linux via the native `ps -o` path.
#
# The assertions are platform-neutral: each must hold on BOTH the native
# `ps -o` path and the MSYS `ps -f` fallback. Nothing here mocks ps; the shim
# is exercised against this live test process ($$).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-ps-portable.sh
. "$ROOT/bin/fm-ps-portable.sh"

test_native_flag_is_boolean() {
  case "${FM_PS_NATIVE:-unset}" in
    0|1) pass "FM_PS_NATIVE resolved to a boolean ($FM_PS_NATIVE)" ;;
    *) fail "FM_PS_NATIVE should be 0 or 1, got '${FM_PS_NATIVE:-unset}'" ;;
  esac
}

test_comm_of_self_is_bash() {
  local comm
  comm=$(fm_ps_field comm "$$") || fail "fm_ps_field comm returned non-zero for self"
  # The test process is bash on every platform; comm must name it.
  assert_contains "$comm" "bash" "comm of the test process should mention bash"
  pass "fm_ps_field comm resolves the current process ($comm)"
}

test_ppid_of_self_is_numeric() {
  local ppid
  ppid=$(fm_ps_field ppid "$$")
  case "$ppid" in
    ''|*[!0-9]*) fail "fm_ps_field ppid should be numeric, got '$ppid'" ;;
    *) pass "fm_ps_field ppid is numeric ($ppid)" ;;
  esac
}

test_args_of_self_mentions_bash() {
  local args
  args=$(fm_ps_field args "$$")
  assert_contains "$args" "bash" "args of the test process should mention bash"
  pass "fm_ps_field args returns the command line"
}

test_identity_of_self_nonempty() {
  local id
  id=$(fm_ps_field identity "$$") || fail "fm_ps_field identity returned non-zero for self"
  [ -n "$id" ] || fail "fm_ps_field identity should be non-empty"
  pass "fm_ps_field identity returns a fingerprint"
}

test_bogus_pid_yields_empty() {
  # A nonexistent pid must yield empty output on both paths (native prints
  # nothing; the fallback returns non-zero). Assert on output, not exit code,
  # so the check is platform-neutral.
  local out
  out=$(fm_ps_field ppid 999999 2>/dev/null || true)
  [ -z "$out" ] || fail "fm_ps_field ppid for a bogus pid should be empty, got '$out'"
  pass "fm_ps_field yields empty for a nonexistent pid"
}

test_source_is_idempotent() {
  local before=$FM_PS_NATIVE
  # shellcheck source=bin/fm-ps-portable.sh
  . "$ROOT/bin/fm-ps-portable.sh"
  expect_code 0 "$?" "re-sourcing the shim"
  [ "$FM_PS_NATIVE" = "$before" ] || fail "FM_PS_NATIVE changed on re-source ($before -> $FM_PS_NATIVE)"
  pass "sourcing the shim twice is idempotent"
}

test_native_flag_is_boolean
test_comm_of_self_is_bash
test_ppid_of_self_is_numeric
test_args_of_self_mentions_bash
test_identity_of_self_nonempty
test_bogus_pid_yields_empty
test_source_is_idempotent
