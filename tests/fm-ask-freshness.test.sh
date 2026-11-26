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

test_pipeless_and_short_rows_are_checked_not_skipped() {
  local report out rc=0
  report=$(write_report pipeless \
    'item | checked_at' \
    '--- | ---' \
    'old ask')
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "a pipe-less row holding only an ask must fail the gate"$'\n'"$out"
  assert_contains "$out" "line 7: UNREADABLE unknown age (checked_at ''): old ask" "the pipe-less row must be named with its line"
  assert_not_contains "$out" "rows are within" "an undated row must not pass"
  rc=0
  report=$(write_report short \
    '| item | action | checked_at |' \
    '|---|---|---|' \
    '| a | send | 2026-11-13T11:30Z |' \
    '| b | merge |' \
    '| c | ping | 2026-11-13T11:40Z |')
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "a short row with no timestamp cell must fail the gate"$'\n'"$out"
  assert_contains "$out" "1 of 3 rows are older than 2h or have no readable checked_at" "every row must be counted"
  assert_contains "$out" "  line 8: UNREADABLE unknown age (checked_at ''): | b | merge |" "the short row must be named with its line"
  assert_contains "$out" "line 9: fresh age 20m" "rows after the short row are still checked"
  pass "pipe-less and short rows are checked and fail when undated"
}

test_out_of_range_offsets_are_unreadable_and_later_rows_still_checked() {
  local report out rc=0
  report=$(write_report offsets \
    '| item | checked_at |' \
    '|---|---|' \
    '| a | 2026-11-13T12:00+24:00 |' \
    '| b | 2026-11-13T12:00+01:99 |' \
    '| c | 2026-11-13T11:30Z |')
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "out-of-range offsets must fail the gate"$'\n'"$out"
  assert_contains "$out" "  line 7: UNREADABLE unknown age (checked_at '2026-11-13T12:00+24:00'): | a |" "a +24:00 offset is unreadable and named"
  assert_contains "$out" "  line 8: UNREADABLE unknown age (checked_at '2026-11-13T12:00+01:99'): | b |" "a +01:99 offset is unreadable, not normalized"
  assert_contains "$out" "line 9: fresh age 30m (checked_at 2026-11-13T11:30Z): | c |" "the row after them is still checked"
  assert_not_contains "$out" "Traceback" "a bad offset must not crash the report"
  pass "out-of-range offsets are unreadable and later rows are still checked"
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
  rc=0
  report=$(write_report header-only '| item | checked_at |' '|---|---|')
  out=$(run_gate "$report") || rc=$?
  expect_code 2 "$rc" "a table with no rows must not report success"$'\n'"$out"
  assert_contains "$out" "has no table rows to check" "the error must say no row was checked"
  pass "usage and input errors exit 2"
}

# A block that starts immediately after a table ends its body. Without that
# rule the heading (or fence, thematic break, or list item) was read as a table row with
# no timestamp cell, so a wholly fresh report failed with exit 1.
test_a_block_after_a_table_ends_the_body_instead_of_becoming_a_row() {
  local report out rc=0
  report="$TMP_ROOT/block-after-table.md"
  {
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| heading case | 2026-11-13T11:30Z |'
    printf '%s\n' '## Next section'
    printf '%s\n' 'Prose under the heading.'
    printf '%s\n' ''
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| fence case | 2026-11-13T11:40Z |'
    printf '%s\n' '```text'
    printf '%s\n' 'not a table row'
    printf '%s\n' '```'
    printf '%s\n' ''
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| break case | 2026-11-13T11:45Z |'
    printf '%s\n' '---'
    printf '%s\n' 'After the break.'
    printf '%s\n' ''
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| list case | 2026-11-13T11:50Z |'
    printf '%s\n' '- follow up note'
    printf '%s\n' '1. second'
  } > "$report"
  out=$(run_gate "$report") || rc=$?
  expect_code 0 "$rc" "a block starting right after a table must not be read as a row"$'\n'"$out"
  assert_contains "$out" "line 3: fresh age 30m" "the row before the heading must be checked"
  assert_contains "$out" "line 9: fresh age 20m" "the row before the fence must be checked"
  assert_contains "$out" "line 16: fresh age 15m" "the row before the thematic break must be checked"
  assert_contains "$out" "line 22: fresh age 10m" "the row before the list must be checked"
  assert_contains "$out" "all 4 rows are within 2h" "only the dated rows are counted"
  assert_not_contains "$out" "UNREADABLE" "a block is not an undated row"
  pass "a heading, fence, thematic break or list right after a table ends its body"
}

# The same rule must not stop short rows being checked: a table whose short
# undated row is followed directly by a heading still fails and names that row.
test_a_short_row_before_a_block_is_still_checked_and_named() {
  local report out rc=0
  report="$TMP_ROOT/short-row-before-heading.md"
  {
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| old ask |'
    printf '%s\n' '## Next section'
  } > "$report"
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "a short undated row before a heading must still fail"$'\n'"$out"
  assert_contains "$out" "1 of 1 rows" "the heading must not be counted as a row"
  assert_contains "$out" "line 3: UNREADABLE unknown age (checked_at ''): | old ask |" \
    "the short row must be named with its line"
  pass "a short row before a block is still checked, and the block is not counted"
}

# A line holding a pipe stays a row even when it begins like a list item or a
# heading, so a stale row in a table without outer pipes is checked, not dropped.
test_a_piped_line_that_looks_like_a_block_is_still_a_row() {
  local report out rc=0
  report="$TMP_ROOT/piped-list-row.md"
  {
    printf '%s\n' 'item | checked_at'
    printf '%s\n' '--- | ---'
    printf '%s\n' 'a | 2026-11-13T11:30Z'
    printf '%s\n' '2. resend reply | 2026-11-13T02:00Z'
    printf '%s\n' '- ping owner | 2026-11-13T01:00Z'
    printf '%s\n' '# retry | 2026-11-13T00:30Z'
    printf '%s\n' '- follow up note'
  } > "$report"
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "a stale row that begins like a list item must fail the gate"$'\n'"$out"
  assert_contains "$out" "3 of 4 rows are older than 2h" "every piped row must be counted, the pipe-less note must not"
  assert_contains "$out" "line 4: STALE" "the numbered row must be checked"
  assert_contains "$out" "line 5: STALE" "the bulleted row must be checked"
  assert_contains "$out" "line 6: STALE" "the heading-like row must be checked"
  assert_not_contains "$out" "follow up note" "a pipe-less list item still ends the body"
  pass "a piped line that begins like a list item or heading is still a checked row"
}

# A table inside a fenced code block is an example, not a triage table, so
# an undated example after a fresh table does not fail the report.
test_a_table_inside_a_fence_is_not_a_triage_table() {
  local report out rc=0
  report="$TMP_ROOT/fenced-example.md"
  {
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| a | 2026-11-13T11:30Z |'
    printf '%s\n' ''
    printf '%s\n' '````markdown'
    printf '%s\n' '| item | action |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '```'
    printf '%s\n' '| b | old ask |'
    printf '%s\n' '````'
    printf '%s\n' ''
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| c | 2026-11-13T02:00Z |'
  } > "$report"
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "the table after the fence must still be checked"$'\n'"$out"
  assert_contains "$out" "line 3: fresh age 30m" "the table before the fence must be checked"
  assert_contains "$out" "line 14: STALE" "the table after the fence must be checked"
  assert_contains "$out" "1 of 2 rows" "rows inside the fence must not be counted"
  assert_not_contains "$out" "no 'checked_at' column" "a fenced example is not an undated table"
  pass "a table inside a fenced code block is skipped"
}

# A line of inline code that starts with backticks is not an opening fence
# (a backtick fence's info string has no backtick), so a later stale table
# is still checked.
test_inline_code_does_not_open_a_fence() {
  local report out rc=0
  report="$TMP_ROOT/inline-code.md"
  {
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| a | 2026-11-13T11:30Z |'
    printf '%s\n' ''
    # shellcheck disable=SC2016 # Literal Markdown inline code, not a command substitution.
    printf '%s\n' '```fm --help``` now lists the flag.'
    printf '%s\n' ''
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| b | 2026-11-13T02:00Z |'
  } > "$report"
  out=$(run_gate "$report") || rc=$?
  expect_code 1 "$rc" "inline code must not hide the stale table"$'\n'"$out"
  assert_contains "$out" "line 9: STALE" "the table after the inline code must be checked"
  pass "a line of inline code does not open a fence"
}

# A closing HTML tag right after a table ends its body, as an opening tag does.
test_a_closing_html_tag_ends_the_table_body() {
  local report out rc=0
  report="$TMP_ROOT/details-table.md"
  {
    printf '%s\n' '<details>'
    printf '%s\n' '<summary>Triage</summary>'
    printf '%s\n' ''
    printf '%s\n' '| item | checked_at |'
    printf '%s\n' '| --- | --- |'
    printf '%s\n' '| a | 2026-11-13T11:30Z |'
    printf '%s\n' '</details>'
  } > "$report"
  out=$(run_gate "$report") || rc=$?
  expect_code 0 "$rc" "a closing tag must not be read as a row"$'\n'"$out"
  assert_contains "$out" "all 1 rows are within 2h" "only the dated row is counted"
  assert_not_contains "$out" "UNREADABLE" "the closing tag is not an undated row"
  pass "a closing HTML tag ends the table body"
}

fm_test_run test_fresh_rows_pass_and_every_row_is_printed_with_its_age \
  test_an_over_age_row_fails_and_is_named_without_editing_the_report \
  test_column_and_max_age_options \
  test_offsets_and_local_time_are_honoured \
  test_unreadable_timestamps_fail_closed \
  test_pipeless_and_short_rows_are_checked_not_skipped \
  test_out_of_range_offsets_are_unreadable_and_later_rows_still_checked \
  test_a_table_without_the_column_fails_even_beside_a_fresh_table \
  test_input_errors_exit_two \
  test_a_block_after_a_table_ends_the_body_instead_of_becoming_a_row \
  test_a_short_row_before_a_block_is_still_checked_and_named \
  test_a_piped_line_that_looks_like_a_block_is_still_a_row \
  test_a_table_inside_a_fence_is_not_a_triage_table \
  test_inline_code_does_not_open_a_fence \
  test_a_closing_html_tag_ends_the_table_body
