#!/usr/bin/env bash
# fm-ask-freshness.sh: a captain ask drawn from a triage list is gated on how
# long ago each row was checked, and the report itself is never edited.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-ask-freshness.sh"
TMP_ROOT=$(fm_test_tmproot fm-ask-freshness)
mkdir -p "$TMP_ROOT"
# 2026-11-13T12:00:00Z
NOW=1794571200

run_gate() {  # <args...>: stdout and stderr together, with a fixed clock
  env TZ=UTC FM_ASK_FRESHNESS_NOW="$NOW" "$GATE" "$@" 2>&1
}

write_report() {  # <name> <table-rows...>: a triage report around one table
  local f="$TMP_ROOT/$1.md"
  shift
  {
    echo "# Triage"
    echo
    echo "Some prose before the table."
    echo
    printf '%s\n' "$@"
    echo
    echo "Prose after."
  } > "$f"
  printf '%s\n' "$f"
}

test_fresh_rows_pass_and_every_row_is_printed_with_its_age() {
  local report out rc=0
  report=$(write_report fresh \
    '| item | action | checked_at |' \
    '|------|--------|------------|' \
    '| a | send reminder | 2026-11-13T11:25Z |' \
    '| b | merge MR | 2026-11-13T10:30:00Z |')
  out=$(run_gate "$report") || rc=$?
  expect_code 0 "$rc" "rows within the default 2h must pass"$'\n'"$out"
  assert_contains "$out" "fresh age 35m (checked_at 2026-11-13T11:25Z): | a | send reminder |" "row a must be printed with its age"
  assert_contains "$out" "fresh age 1h30m" "row b must be printed with its age"
  assert_contains "$out" "all 2 rows are within 2h" "the summary must count the checked rows"
  pass "fresh rows pass and every row is printed with its age"
}

test_an_over_age_row_fails_and_is_named_without_editing_the_report() {
  local report out rc=0 before
  report=$(write_report stale \
    '| item | action | checked_at |' \
    '|---|---|---|' \
    '| a | send reminder | 2026-11-13T04:00Z |' \
    '| b | merge MR | 2026-11-13T11:50Z |')
  before=$(cksum < "$report")
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "an 8h-old row must fail the gate"$'\n'"$out"
  assert_contains "$out" "STALE age 8h00m" "the stale row must be printed with its age"
  assert_contains "$out" "fresh age 10m" "the fresh row must still be printed"
  assert_contains "$out" "1 of 2 rows are older than 2h" "the failure must count the over-age rows"
  assert_contains "$out" "  line 7: STALE age 8h00m (checked_at 2026-11-13T04:00Z): | a | send reminder |" \
    "the failure must name the over-age row"
  [ "$(cksum < "$report")" = "$before" ] || fail "the gate must never edit the report"
  pass "an over-age row fails the gate, is named, and the report is untouched"
}

test_column_and_max_age_options() {
  local report out rc=0
  report=$(write_report options \
    '| item | **Verified** |' \
    '|:-----|-----------:|' \
    '| a | 2026-11-13 09:00 |' \
    '| b | 2026-11-13T10:15:00+00:00 |')
  out=$(run_gate "$report" --column verified --max-age 4h) || rc=$?
  expect_code 0 "$rc" "a 3h-old row must pass a 4h bound"$'\n'"$out"
  assert_contains "$out" "fresh age 3h00m (verified 2026-11-13 09:00)" "the plain date-time form is read"
  rc=0
  out=$(run_gate "$report" --column verified --max-age 1h30m) || rc=$?
  expect_code 1 "$rc" "a 1h45m-old row must fail a 1h30m bound"$'\n'"$out"
  assert_contains "$out" "STALE age 1h45m" "the offset form is read"
  rc=0
  out=$(run_gate "$report" --max-age 4h) || rc=$?
  expect_code 2 "$rc" "a report without the default column must be an input error"$'\n'"$out"
  assert_contains "$out" "  table at line 5: no 'checked_at' column" "the error must name the table and the missing column"
  pass "--column picks the timestamp column and --max-age sets the bound"
}

test_offsets_and_local_time_are_honoured() {
  local report out rc=0
  report=$(write_report zones \
    '| item | checked_at |' \
    '|---|---|' \
    '| a | 2026-11-13T12:30+01:00 |' \
    '| b | 2026-11-13 11:00 |')
  out=$(env TZ=Asia/Kolkata FM_ASK_FRESHNESS_NOW="$NOW" "$GATE" "$report" 2>&1) || rc=$?
  expect_code 1 "$rc" "a local time read in a +05:30 zone is 6h30m old"$'\n'"$out"
  assert_contains "$out" "fresh age 30m (checked_at 2026-11-13T12:30+01:00)" "an explicit offset must be honoured"
  assert_contains "$out" "STALE age 6h30m (checked_at 2026-11-13 11:00)" "a time with no offset is local time"
  pass "explicit offsets are honoured and a time with no offset is read in local time"
}

test_unreadable_timestamps_fail_closed() {
  local report out rc=0
  report=$(write_report unreadable \
    '| item | checked_at |' \
    '|---|---|' \
    '| a | |' \
    '| b | 2026-11-13 |' \
    '| c | yesterday |' \
    '| d | 2026-11-13T18:00Z |' \
    '| e | 2026-11-13T11:59Z |')
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "rows that cannot be dated must fail the gate"$'\n'"$out"
  assert_contains "$out" "4 of 5 rows are older than 2h or have no readable checked_at" "every undatable row must be counted"
  assert_contains "$out" "UNREADABLE unknown age (checked_at ''): | a |" "an empty cell is unreadable"
  assert_contains "$out" "UNREADABLE unknown age (checked_at '2026-11-13')" "a date with no time is unreadable"
  assert_contains "$out" "UNREADABLE unknown age (checked_at 'yesterday')" "prose is unreadable"
  assert_contains "$out" "is in the future" "a future time is unreadable"
  assert_contains "$out" "fresh age 1m" "a readable row is still checked"
  pass "empty, date-only, prose, and future timestamps fail closed"
}

test_a_table_without_the_column_fails_even_beside_a_fresh_table() {
  local report out rc=0
  report=$(write_report mixed \
    '| item | action |' \
    '|---|---|' \
    '| a | send reminder |' \
    '' \
    '| item | checked_at |' \
    '|---|---|' \
    '| b | 2026-11-13T11:30Z |')
  out=$(run_gate "$report") || rc=$?
  expect_code 2 "$rc" "an undated table must fail the gate even when another table is fresh"$'\n'"$out"
  assert_contains "$out" "fresh age 30m (checked_at 2026-11-13T11:30Z): | b |" "the dated table's rows are still printed with their age"
  assert_contains "$out" "1 table(s) in '$report' have no 'checked_at' column" "the failure must count the undated tables"
  assert_contains "$out" "  table at line 5: no 'checked_at' column" "the failure must name the undated table"
  assert_not_contains "$out" "all 1 rows are within" "an undated table must not be reported as passing"
  pass "a table without the timestamp column fails the gate even beside a fresh table"
}

test_input_errors_exit_two() {
  local report out rc=0
  report=$(write_report errors '| item | checked_at |' '|---|---|' '| a | 2026-11-13T11:00Z |')
  out=$(run_gate "$report" --max-age soon) || rc=$?
  expect_code 2 "$rc" "a malformed duration must be an input error"
  assert_contains "$out" "--max-age 'soon' is not a duration" "the error must name the bad duration"
  rc=0
  out=$(run_gate "$TMP_ROOT/absent.md") || rc=$?
  expect_code 2 "$rc" "a missing report must be an input error"
  rc=0
  out=$(run_gate) || rc=$?
  expect_code 2 "$rc" "a missing argument must be an input error"
  rc=0
  out=$(run_gate "$report" --column) || rc=$?
  expect_code 2 "$rc" "--column with no value must be an input error"
  rc=0
  printf '# Triage\n\nNo table here.\n' > "$TMP_ROOT/no-table.md"
  out=$(run_gate "$TMP_ROOT/no-table.md") || rc=$?
  expect_code 2 "$rc" "a report with no table must be an input error"
  assert_contains "$out" "has no markdown table" "the error must say there is no table"
  pass "usage and input errors exit 2"
}

fm_test_run test_fresh_rows_pass_and_every_row_is_printed_with_its_age \
  test_an_over_age_row_fails_and_is_named_without_editing_the_report \
  test_column_and_max_age_options \
  test_offsets_and_local_time_are_honoured \
  test_unreadable_timestamps_fail_closed \
  test_a_table_without_the_column_fails_even_beside_a_fresh_table \
  test_input_errors_exit_two
