#!/usr/bin/env bash
# Behavior tests for bin/fm-test-tap-verify.sh: a TAP-planned suite that
# finishes cleanly passes; an early exit 0, a not-ok line, a nonzero status,
# or an ok-count that disagrees with the plan must fail. This is the
# completeness check that replaced hard-coded ok-counts in the stock macOS
# Bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-test-tap-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-tap-verify)
assert_present "$VERIFY" "bin/fm-test-tap-verify.sh is missing"

write_suite() {  # <path> <body>
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' "$2" > "$1"
}

run_verify() {  # <suite> -> prints merged output; returns helper status
  "$BASH" "$VERIFY" "$1" 2>&1
}

test_correct_suite_passes() {
  local suite out rc=0
  suite="$TMP_ROOT/ok.sh"
  write_suite "$suite" '
printf "1..1\n"
printf "ok - good\n"
printf "FM_TEST_COMPLETE\n"
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -eq 0 ] || fail "a complete matching suite must pass, got exit $rc: $out"
  assert_contains "$out" "ok - good" "the helper hid the suite's ok line"
  assert_contains "$out" "1 planned, 1 ok, complete, exit 0" \
    "the helper did not confirm a matching plan"
  assert_not_contains "$out" "::error::" \
    "a passing suite must not print ::error::: $out"
  pass "a complete matching suite passes"
}

test_early_exit_zero_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/early.sh"
  write_suite "$suite" '
printf "1..3\n"
printf "ok - one\n"
printf "ok - two\n"
exit 0
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "an early exit 0 must fail the helper: $out"
  assert_contains "$out" "without a single FM_TEST_COMPLETE" \
    "an early exit 0 must name the missing completion marker: $out"
  pass "an early exit 0 fails even when some ok lines printed"
}

test_not_ok_fails_even_with_exit_zero() {
  local suite out rc=0
  suite="$TMP_ROOT/not-ok.sh"
  write_suite "$suite" '
printf "1..1\n"
printf "not ok - boom\n"
printf "ok - misleading\n"
printf "FM_TEST_COMPLETE\n"
exit 0
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a not-ok line with exit 0 must fail: $out"
  assert_contains "$out" "not-ok" "a not-ok line must be named: $out"
  pass "a not-ok line fails even when the suite exits 0"
}

test_nonzero_exit_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/nonzero.sh"
  write_suite "$suite" '
printf "1..1\n"
printf "ok - good\n"
printf "FM_TEST_COMPLETE\n"
exit 7
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a nonzero suite status must fail the helper: $out"
  assert_contains "$out" "exited 7" "a nonzero status must be reported: $out"
  pass "a nonzero process status fails even with a matching TAP plan"
}

test_ok_count_mismatch_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/mismatch.sh"
  write_suite "$suite" '
printf "1..2\n"
printf "ok - only-one\n"
printf "FM_TEST_COMPLETE\n"
'
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "planned 2 / ok 1 must fail: $out"
  assert_contains "$out" "planned 2 ok lines, got 1" \
    "an ok-count mismatch must be reported: $out"
  pass "planned count must equal the number of ok lines"
}

test_fm_test_run_declares_plan_from_names() {
  local suite out rc=0
  suite="$TMP_ROOT/lib-run.sh"
  cat > "$suite" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"
test_alpha() { pass "alpha"; }
test_beta() { pass "beta"; }
fm_test_run test_alpha test_beta
EOF
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -eq 0 ] || fail "fm_test_run suite must pass the helper, got exit $rc: $out"
  assert_contains "$out" "1..2" "fm_test_run must print a plan derived from its names"
  assert_contains "$out" "ok - alpha" "fm_test_run lost the first test"
  assert_contains "$out" "ok - beta" "fm_test_run lost the second test"
  assert_contains "$out" "FM_TEST_COMPLETE" "fm_test_run must print the completion marker"
  assert_contains "$out" "2 planned, 2 ok, complete, exit 0" \
    "the helper must accept an fm_test_run plan"
  pass "fm_test_run derives N from the registered names"
}

test_fm_test_run_early_function_exit_fails() {
  local suite out rc=0
  suite="$TMP_ROOT/lib-early.sh"
  cat > "$suite" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"
test_alpha() { pass "alpha"; exit 0; }
test_beta() { pass "beta"; }
fm_test_run test_alpha test_beta
EOF
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a test function that exits 0 early must fail completeness: $out"
  assert_contains "$out" "without a single FM_TEST_COMPLETE" \
    "early function exit must name the missing completion marker: $out"
  pass "a test function that exits 0 before later tests fail completeness"
}

test_failure_prints_error_annotation() {
  local suite out rc=0
  suite="$TMP_ROOT/gha.sh"
  write_suite "$suite" 'exit 0'
  # Capture the helper's stdout and stderr so a passing self-test does not
  # leak ::error:: into the CI log.
  out=$(run_verify "$suite") || rc=$?
  [ "$rc" -ne 0 ] || fail "a suite with no plan must fail: $out"
  assert_contains "$out" "::error::" "a completeness failure must emit an error annotation: $out"
  pass "a completeness failure prints an error annotation"
}

test_correct_suite_passes
test_early_exit_zero_fails
test_not_ok_fails_even_with_exit_zero
test_nonzero_exit_fails
test_ok_count_mismatch_fails
test_fm_test_run_declares_plan_from_names
test_fm_test_run_early_function_exit_fails
test_failure_prints_error_annotation
