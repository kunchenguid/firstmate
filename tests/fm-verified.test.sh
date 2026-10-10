#!/usr/bin/env bash
# Behavior tests for fm-verified.sh: a receipt written by record is read back by
# check and show, check refuses to answer without --head, its verified, stale,
# never, and failed paths each exit with their own code, a second record
# replaces the receipt instead of appending, no prose in the home can make an
# unverified head read as verified, and a receipt reached through a symlink is
# refused rather than answered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFIED="$ROOT/bin/fm-verified.sh"
TMP_ROOT=$(fm_test_tmproot fm-verified)
HEAD_A=0cf612c9a1b2c3d4e5f60718293a4b5c6d7e8f90
HEAD_B=1122334455667788990011223344556677889900

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# run_verified <home> <out> <err> <args...>: echoes the exit status.
run_verified() {
  local home=$1 out=$2 err=$3 status=0
  shift 3
  FM_HOME="$home" "$VERIFIED" "$@" >"$out" 2>"$err" || status=$?
  printf '%s\n' "$status"
}

test_pass_stale_never_and_fail_each_have_their_own_code() {
  local home out err status
  home=$(make_home verdicts)
  out="$home/out.txt"
  err="$home/err.txt"

  status=$(run_verified "$home" "$out" "$err" \
    record api --head "$HEAD_A" --verdict pass --note "verifier clean")
  expect_code 0 "$status" "record a passing receipt"

  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 0 "$status" "check at the recorded head"
  assert_contains "$(cat "$out")" "verified:" "pass at the recorded head did not report verified"
  assert_contains "$(cat "$out")" "recorded-head=$HEAD_A" "verified line omitted the recorded head"
  assert_contains "$(cat "$out")" "asked-head=$HEAD_A" "verified line omitted the head asked about"
  assert_equals 1 "$(wc -l < "$out" | tr -d ' ')" "check printed more than one line"

  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_B")
  expect_code 3 "$status" "check at a head the receipt does not cover"
  assert_contains "$(cat "$out")" "stale:" "a pass at another head did not report stale"
  assert_contains "$(cat "$out")" "recorded-head=$HEAD_A" "stale line omitted the recorded head"
  assert_contains "$(cat "$out")" "asked-head=$HEAD_B" "stale line omitted the head asked about"

  status=$(run_verified "$home" "$out" "$err" check nothing-here --head "$HEAD_A")
  expect_code 4 "$status" "check a subject with no receipt"
  assert_contains "$(cat "$out")" "never:" "a subject with no receipt did not report never"
  assert_contains "$(cat "$out")" "asked-head=$HEAD_A" "never line omitted the head asked about"

  status=$(run_verified "$home" "$out" "$err" record gate --head "$HEAD_A" --verdict fail)
  expect_code 0 "$status" "record a failing receipt"
  status=$(run_verified "$home" "$out" "$err" check gate --head "$HEAD_A")
  expect_code 5 "$status" "check a recorded fail at the same head"
  assert_contains "$(cat "$out")" "failed:" "a recorded fail did not report failed"
  assert_contains "$(cat "$out")" "recorded-verdict=fail" "failed line omitted the recorded verdict"

  pass "verified, stale, never and failed each exit with their own code"
}

test_check_refuses_without_a_head() {
  local home out err status
  home=$(make_home no-head)
  out="$home/out.txt"
  err="$home/err.txt"
  status=$(run_verified "$home" "$out" "$err" record api --head "$HEAD_A" --verdict pass)
  expect_code 0 "$status" "record before the bare check"

  status=$(run_verified "$home" "$out" "$err" check api)
  expect_code 2 "$status" "check with no --head"
  assert_contains "$(cat "$err")" "--head" "the bare-check refusal did not name --head"
  assert_equals "" "$(cat "$out")" "check with no --head still answered on stdout"

  status=$(run_verified "$home" "$out" "$err" check api --head)
  expect_code 2 "$status" "check with a valueless --head"
  assert_equals "" "$(cat "$out")" "check with a valueless --head still answered on stdout"

  status=$(run_verified "$home" "$out" "$err" check api --head HEAD)
  expect_code 2 "$status" "check with a branch-style head"
  assert_equals "" "$(cat "$out")" "check with a non-commit head still answered on stdout"

  pass "check refuses to answer without a head that names one commit"
}

test_record_is_read_back_and_replaced_not_appended() {
  local home out err status first_recorded
  home=$(make_home replace)
  out="$home/out.txt"
  err="$home/err.txt"

  status=$(run_verified "$home" "$out" "$err" \
    record api --head "$HEAD_A" --verdict pass --evidence reports/first.md --note "first pass")
  expect_code 0 "$status" "record the first receipt"
  status=$(run_verified "$home" "$out" "$err" show api)
  expect_code 0 "$status" "show the first receipt"
  assert_contains "$(cat "$out")" "head=$HEAD_A" "show omitted the recorded head"
  assert_contains "$(cat "$out")" "verdict=pass" "show omitted the recorded verdict"
  assert_contains "$(cat "$out")" "evidence=reports/first.md" "show omitted the recorded evidence"
  assert_contains "$(cat "$out")" "note=first pass" "show omitted the recorded note"
  first_recorded=$(cat "$out")

  status=$(run_verified "$home" "$out" "$err" record api --head "$HEAD_B" --verdict fail)
  expect_code 0 "$status" "re-record the same subject"
  status=$(run_verified "$home" "$out" "$err" show api)
  expect_code 0 "$status" "show the replacing receipt"
  assert_contains "$(cat "$out")" "head=$HEAD_B" "the replacing receipt did not carry the new head"
  assert_contains "$(cat "$out")" "verdict=fail" "the replacing receipt did not carry the new verdict"
  assert_not_contains "$(cat "$out")" "$HEAD_A" "the replaced head survived the re-record"
  assert_not_contains "$(cat "$out")" "first pass" "the replaced note survived the re-record"
  assert_not_equals "$first_recorded" "$(cat "$out")" "the re-record left the receipt unchanged"
  assert_equals 1 "$(find "$home/state/verified" -name 'api.receipt' | wc -l | tr -d ' ')" \
    "re-recording did not keep exactly one receipt for the subject"

  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 3 "$status" "the superseded head still reads as covered"

  pass "a receipt reads back through show and check, and a re-record replaces it"
}

test_show_reports_a_missing_receipt_plainly() {
  local home out err status
  home=$(make_home show-missing)
  out="$home/out.txt"
  err="$home/err.txt"
  status=$(run_verified "$home" "$out" "$err" show absent-subject)
  expect_code 4 "$status" "show a subject with no receipt"
  assert_contains "$(cat "$out")" "never:" "show did not report the missing receipt plainly"
  assert_contains "$(cat "$out")" "absent-subject" "show did not name the subject"
  pass "show reports a missing receipt plainly"
}

test_prose_in_the_home_never_answers_the_question() {
  local home out err status
  home=$(make_home prose)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'done: verifier pass at %s\n' "$HEAD_A" > "$home/state/api.status"
  mkdir -p "$home/data/api"
  printf 'The verifier passed. Everything is verified.\n' > "$home/data/api/report.md"

  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 4 "$status" "a status line stood in for a receipt"
  assert_contains "$(cat "$out")" "never:" "prose in the home produced a verdict"
  assert_not_contains "$(cat "$out")" "verifier" "check echoed prose from the home"

  status=$(run_verified "$home" "$out" "$err" record api --head "$HEAD_B" --verdict pass)
  expect_code 0 "$status" "record a receipt for a later head"
  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 3 "$status" "a status line about an older head read as covered"
  assert_contains "$(cat "$out")" "stale:" "prose about the older head produced a pass"

  pass "no status line or report in the home can answer the verification question"
}

test_a_redirected_receipt_is_refused_not_answered() {
  local home elsewhere out err status
  home=$(make_home redirected)
  elsewhere="$TMP_ROOT/elsewhere"
  out="$home/out.txt"
  err="$home/err.txt"
  status=$(run_verified "$home" "$out" "$err" record api --head "$HEAD_A" --verdict pass)
  expect_code 0 "$status" "record before redirecting the receipt"

  mv "$home/state/verified/api.receipt" "$home/state/api.receipt.real"
  ln -s "$home/state/api.receipt.real" "$home/state/verified/api.receipt"
  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 1 "$status" "check a receipt reached through a symlink"
  assert_not_contains "$(cat "$out")" "verified:" "a symlinked receipt still answered verified"
  status=$(run_verified "$home" "$out" "$err" show api)
  expect_code 1 "$status" "show a receipt reached through a symlink"

  rm -rf "$home/state/verified"
  mkdir -p "$elsewhere"
  cp "$home/state/api.receipt.real" "$elsewhere/api.receipt"
  ln -s "$elsewhere" "$home/state/verified"
  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 1 "$status" "check through a symlinked receipt directory"
  assert_not_contains "$(cat "$out")" "verified:" "a symlinked receipt directory still answered verified"
  status=$(run_verified "$home" "$out" "$err" record api --head "$HEAD_B" --verdict pass)
  expect_code 1 "$status" "record through a symlinked receipt directory"

  pass "a receipt reached through a symlink is refused rather than answered"
}

test_a_dangling_receipt_symlink_is_refused_not_never() {
  local home out err status
  home=$(make_home dangling)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir -p "$home/state/verified"
  ln -s "$TMP_ROOT/nonexistent.receipt" "$home/state/verified/api.receipt"
  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 1 "$status" "check a dangling receipt symlink"
  assert_not_contains "$(cat "$out")" "verified:" "a dangling receipt symlink answered verified"
  assert_not_contains "$(cat "$out")" "never:" "a dangling receipt symlink answered never"
  status=$(run_verified "$home" "$out" "$err" show api)
  expect_code 1 "$status" "show a dangling receipt symlink"
  assert_not_contains "$(cat "$out")" "verified:" "show of a dangling receipt symlink answered verified"
  assert_not_contains "$(cat "$out")" "never:" "show of a dangling receipt symlink answered never"

  rm -rf "$home/state/verified"
  ln -s "$TMP_ROOT/nonexistent-dir" "$home/state/verified"
  status=$(run_verified "$home" "$out" "$err" record api --head "$HEAD_A" --verdict pass)
  expect_code 1 "$status" "record through a dangling receipt directory symlink"
  status=$(run_verified "$home" "$out" "$err" check api --head "$HEAD_A")
  expect_code 1 "$status" "check through a dangling receipt directory symlink"
  assert_not_contains "$(cat "$out")" "verified:" "a dangling receipt directory symlink answered verified"
  assert_not_contains "$(cat "$out")" "never:" "a dangling receipt directory symlink answered never"
  status=$(run_verified "$home" "$out" "$err" show api)
  expect_code 1 "$status" "show through a dangling receipt directory symlink"
  assert_not_contains "$(cat "$out")" "verified:" "show through a dangling receipt directory symlink answered verified"
  assert_not_contains "$(cat "$out")" "never:" "show through a dangling receipt directory symlink answered never"
  [ ! -e "$TMP_ROOT/nonexistent-dir" ] || fail "record wrote through a dangling receipt directory symlink"

  pass "a dangling receipt symlink is refused rather than answered never"
}

test_pass_stale_never_and_fail_each_have_their_own_code
test_check_refuses_without_a_head
test_record_is_read_back_and_replaced_not_appended
test_show_reports_a_missing_receipt_plainly
test_prose_in_the_home_never_answers_the_question
test_a_redirected_receipt_is_refused_not_answered
test_a_dangling_receipt_symlink_is_refused_not_never
