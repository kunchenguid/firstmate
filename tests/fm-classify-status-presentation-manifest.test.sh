#!/usr/bin/env bash
# tests/fm-classify-status-presentation-manifest.test.sh - regressions for
# $state/.status-presentation-cursor row validation in bin/fm-classify-lib.sh.
#
# Incident: a manifest row with a column count the running reader did not
# expect made status_retire_presentation_task fail with `[ -n "$extra" ] ||
# return 1` and no other output, so bin/fm-teardown.sh exited 1 with nothing on
# stderr. Four already-finished tasks stayed stuck "in flight" because nobody
# could see why cleanup refused to run. Root cause: commit d977128 (PR #3495,
# 2026-09-02) widened this manifest from 3 to 4 TAB-separated fields
# (task, ident, offset, backstop) in the same commit that updated the reader,
# so a process still running the pre-d977128 3-field reader against a
# post-d977128 4-field row it had not yet picked up hit the silent branch.
# Firstmate's own header comment above status_presentation_cursor_offset (bin/
# fm-classify-lib.sh) is this format's one owner; these tests pin its row
# contract from the outside, through the real reader functions, never through
# the manifest's raw bytes.
#
# These tests cover the three malformed-row shapes that class of incident can
# take - an unexpected extra column, a missing field, and a non-numeric offset -
# at the CURRENT valid 4-field width (an extra column today means a 5th field,
# since 4 is the current, correct shape; see the positive control test below).
# Every case asserts BOTH halves of the contract: a stderr line naming the
# manifest path, the row's line number, and the expected format (never a silent
# `return 1`), and that nothing is deleted or rewritten - the fail-closed safety
# that must survive every later change here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-status-presentation-manifest-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s' "$d"
}

# A real ident for a fixture status file, exactly as the library computes it -
# used only for the positive control, since every malformed-row failure below
# triggers on format alone, before any ident comparison runs.
file_ident() {  # <status-file>
  _fm_open_decisions_file_ident "$1"
}

# Run status_retire_presentation_task in a subshell with its own STATE, the way
# bin/fm-teardown.sh does: fm-classify-lib.sh alone has no lock primitives, so
# fm-wake-lib.sh (the real caller's other sourced sibling) supplies
# fm_lock_acquire_wait/fm_lock_release. Captures stdout, stderr, and exit code
# so a test can assert on all three independently.
run_retire() {  # <state> <task> <out> <err>
  local state=$1 task=$2 out=$3 err=$4 rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    # shellcheck disable=SC1090,SC1091
    . "$2"
    status_retire_presentation_task "$3" "$4"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-classify-lib.sh" "$state" "$task" \
    > "$out" 2> "$err" || rc=$?
  return "$rc"
}

# --- status_presentation_cursor_offset: the three malformed-row shapes ------

test_extra_column_fails_loudly_and_names_the_row() {
  local dir state f manifest err rc=0
  dir=$(case_dir extra-column)
  state="$dir/state"
  f="$state/task-a.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-a\tident-a\t12\t0\tstray\n' > "$manifest"
  err="$dir/err"

  status_presentation_cursor_offset "$f" > /dev/null 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "an unexpected extra column did not fail closed (rc=$rc)"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'extra field' "$err" \
    || fail "the error did not name the reason (extra field): $(cat "$err")"
  grep -qF 'task, ident, offset, backstop' "$err" \
    || fail "the error did not state the expected 4-field format: $(cat "$err")"
  pass "a manifest row with one column too many fails closed with a stderr line naming the manifest, line, and expected format"
}

test_missing_field_fails_loudly_and_names_the_row() {
  local dir state f manifest err rc=0
  dir=$(case_dir missing-field)
  state="$dir/state"
  f="$state/task-b.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  # Only task and ident: offset and backstop are absent, not merely empty.
  printf 'task-b\tident-b\n' > "$manifest"
  err="$dir/err"

  status_presentation_cursor_offset "$f" > /dev/null 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a manifest row missing its offset field did not fail closed (rc=$rc)"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'missing' "$err" \
    || fail "the error did not name the reason (missing field): $(cat "$err")"
  pass "a manifest row with a missing field fails closed with a stderr line naming the manifest, line, and expected format"
}

test_non_numeric_offset_fails_loudly_and_names_the_row() {
  local dir state f manifest err rc=0
  dir=$(case_dir non-numeric-offset)
  state="$dir/state"
  f="$state/task-c.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-c\tident-c\tNaN\t0\n' > "$manifest"
  err="$dir/err"

  status_presentation_cursor_offset "$f" > /dev/null 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a non-numeric offset did not fail closed (rc=$rc)"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'non-numeric' "$err" \
    || fail "the error did not name the reason (non-numeric offset): $(cat "$err")"
  pass "a manifest row with a non-numeric offset fails closed with a stderr line naming the manifest, line, and expected format"
}

# A malformed row on ANY task blocks every task's lookup against the same
# manifest, exactly as the reported incident affected four unrelated tasks.
test_a_malformed_row_for_another_task_still_blocks_this_lookup() {
  local dir state f manifest err rc=0
  dir=$(case_dir cross-task-blast-radius)
  state="$dir/state"
  f="$state/task-d.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  {
    printf 'task-d\tident-d\t5\t0\n'
    printf 'task-unrelated\tident-x\tNaN\t0\n'
  } > "$manifest"
  err="$dir/err"

  status_presentation_cursor_offset "$f" > /dev/null 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a malformed row for an unrelated task did not block this task's lookup (rc=$rc)"
  grep -qF "$manifest:2:" "$err" \
    || fail "the error did not name the offending line (2), not the well-formed one: $(cat "$err")"
  pass "one malformed row blocks every task's lookup against the shared manifest, matching the reported blast radius"
}

# Positive control: the historical incident's exact 4-field shape (task, ident,
# offset, "0") is the CURRENT valid format (commit d977128) and must keep
# parsing successfully - this fix only makes an actually malformed row loud,
# it does not narrow what counts as well-formed.
test_the_reported_four_field_row_is_valid_today() {
  local dir state f manifest ident offset err
  dir=$(case_dir reported-shape-is-valid)
  state="$dir/state"
  f="$state/task-e.status"
  printf 'working: setup\nworking: more\n' > "$f"
  ident=$(file_ident "$f") || fail "could not compute a fixture ident"
  manifest="$state/.status-presentation-cursor"
  printf 'task-e\t%s\t7\t0\n' "$ident" > "$manifest"
  err="$dir/err"

  offset=$(status_presentation_cursor_offset "$f" 2> "$err") \
    || fail "the current 4-field format was rejected: $(cat "$err")"
  [ -z "$(cat "$err")" ] || fail "a well-formed row printed an unexpected diagnostic: $(cat "$err")"
  [ "$offset" = 7 ] || fail "the offset from a well-formed row was not read through: got '$offset'"
  pass "the exact 4-field shape from the reported incident is the current valid format and stays silent"
}

# --- status_retire_presentation_task: fm-teardown.sh's own call path --------

test_teardown_retire_surfaces_the_error_and_deletes_nothing() {
  local dir state f manifest out err rc=0
  dir=$(case_dir retire-malformed-manifest)
  state="$dir/state"
  f="$state/task-f.status"
  printf 'done: ready\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-f\tident-f\t4\t0\tstray\n' > "$manifest"
  out="$dir/out"; err="$dir/err"

  run_retire "$state" task-f "$out" "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "status_retire_presentation_task did not fail closed on a malformed manifest (rc=$rc)"
  grep -qF "$manifest:1:" "$err" \
    || fail "status_retire_presentation_task's caller (fm-teardown.sh's own stderr) got no diagnostic: $(cat "$err")"
  grep -qi 'extra field' "$err" \
    || fail "status_retire_presentation_task's diagnostic did not name the reason: $(cat "$err")"
  [ -f "$f" ] || fail "a malformed manifest must never cause the status file to be deleted"
  [ -f "$manifest" ] || fail "a malformed manifest must never be deleted outright"
  grep -qF 'task-f' "$manifest" \
    || fail "the malformed manifest must be left exactly as found, not silently rewritten"
  pass "fm-teardown.sh's own retire call surfaces a manifest error on stderr and leaves the status file and manifest untouched"
}

test_teardown_retire_succeeds_on_a_well_formed_manifest() {
  local dir state f manifest ident out err rc=0
  dir=$(case_dir retire-well-formed-manifest)
  state="$dir/state"
  f="$state/task-g.status"
  printf 'done: ready\n' > "$f"
  ident=$(file_ident "$f") || fail "could not compute a fixture ident"
  manifest="$state/.status-presentation-cursor"
  printf 'task-g\t%s\t4\t0\n' "$ident" > "$manifest"
  out="$dir/out"; err="$dir/err"

  run_retire "$state" task-g "$out" "$err" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "retirement over a well-formed 4-field manifest failed (rc=$rc): $(cat "$err")"
  [ -z "$(cat "$err")" ] || fail "a successful retirement printed an unexpected diagnostic: $(cat "$err")"
  [ ! -e "$f" ] || fail "retirement did not remove the retired task's status file"
  pass "retirement over the current 4-field manifest format still succeeds and stays silent"
}

# An extra column hidden BEHIND an empty column. Reading a row with
# `IFS=$'\t' read -r task ident offset backstop extra` merges the two adjacent
# TABs, so this 5-field row parsed as a well-formed 4-field one whose offset
# silently came from the backstop column - and the next rewrite wrote it back
# as 4 fields, dropping the trailing column. It must fail exactly like a plain
# extra column does.
test_extra_column_behind_an_empty_field_fails_loudly() {
  local dir state f manifest err rc=0
  dir=$(case_dir extra-column-behind-empty-field)
  state="$dir/state"
  f="$state/task-h.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  # 5 fields, the offset column empty: task, ident, "", 7, 0.
  printf 'task-h\tident-h\t\t7\t0\n' > "$manifest"
  err="$dir/err"

  status_presentation_cursor_offset "$f" > /dev/null 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "an extra column behind an empty field did not fail closed (rc=$rc)"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'extra field' "$err" \
    || fail "the error did not name the reason (extra field): $(cat "$err")"
  pass "a surplus column hidden behind an empty column fails closed like any other extra column"
}

test_retire_never_drops_a_column_behind_an_empty_field() {
  local dir state f manifest out err rc=0
  dir=$(case_dir retire-extra-column-behind-empty-field)
  state="$dir/state"
  f="$state/task-i.status"
  printf 'done: ready\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-i\tident-i\t\t7\t0\n' > "$manifest"
  out="$dir/out"; err="$dir/err"

  run_retire "$state" task-i "$out" "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "retirement over a row with a hidden surplus column did not fail closed (rc=$rc)"
  grep -qi 'extra field' "$err" \
    || fail "retirement gave no diagnostic for the hidden surplus column: $(cat "$err")"
  [ -f "$f" ] || fail "a malformed manifest must never cause the status file to be deleted"
  [ "$(cat "$manifest")" = "$(printf 'task-i\tident-i\t\t7\t0')" ] \
    || fail "the manifest was rewritten and lost a column: $(cat "$manifest" | cat -A)"
  pass "retirement never silently rewrites away a column hidden behind an empty column"
}

# The one deliberate tolerance the header comment documents: a pre-d977128
# 3-field row (task, ident, offset) is read as backstop 0 and upgraded to the
# full 4-field shape on the next rewrite, losing nothing.
test_legacy_three_field_row_is_read_and_upgraded_losslessly() {
  local dir state f manifest ident offset backstop err
  dir=$(case_dir legacy-three-field-row)
  state="$dir/state"
  f="$state/task-j.status"
  printf 'working: setup\nworking: more\n' > "$f"
  ident=$(file_ident "$f") || fail "could not compute a fixture ident"
  manifest="$state/.status-presentation-cursor"
  printf 'task-j\t%s\t7\n' "$ident" > "$manifest"
  err="$dir/err"

  offset=$(status_presentation_cursor_offset "$f" 2> "$err") \
    || fail "the legacy 3-field row was rejected: $(cat "$err")"
  [ -z "$(cat "$err")" ] || fail "the legacy 3-field row printed a diagnostic: $(cat "$err")"
  [ "$offset" = 7 ] || fail "the legacy row's offset was not read through: got '$offset'"
  backstop=$(status_outcome_backstop_cursor_offset "$f" 2> "$err") \
    || fail "the legacy 3-field row was rejected by the backstop reader: $(cat "$err")"
  [ "$backstop" = 0 ] || fail "a legacy row without a backstop column must read as 0: got '$backstop'"
  pass "a pre-d977128 3-field row is still read, silently, as backstop 0"
}

test_retire_upgrades_a_legacy_three_field_row_of_another_task() {
  local dir state f manifest ident out err rc=0
  dir=$(case_dir legacy-three-field-row-rewrite)
  state="$dir/state"
  f="$state/task-k.status"
  printf 'done: ready\n' > "$f"
  ident=$(file_ident "$f") || fail "could not compute a fixture ident"
  manifest="$state/.status-presentation-cursor"
  {
    printf 'task-k\t%s\t4\t0\n' "$ident"
    printf 'task-legacy\tident-legacy\t3\n'
  } > "$manifest"
  out="$dir/out"; err="$dir/err"

  run_retire "$state" task-k "$out" "$err" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "retirement alongside a legacy 3-field row failed (rc=$rc): $(cat "$err")"
  [ -z "$(cat "$err")" ] || fail "a legacy 3-field row printed a diagnostic on retirement: $(cat "$err")"
  [ "$(cat "$manifest")" = "$(printf 'task-legacy\tident-legacy\t3\t0')" ] \
    || fail "the surviving legacy row was not carried through as a full 4-field row: $(cat "$manifest")"
  pass "retirement carries an unrelated legacy 3-field row through, upgraded to 4 fields, losing nothing"
}

# --- manifest-level (file, not row) failures --------------------------------

test_symlinked_manifest_fails_loudly_and_deletes_nothing() {
  local dir state f manifest out err rc=0
  dir=$(case_dir symlinked-manifest)
  state="$dir/state"
  f="$state/task-l.status"
  printf 'done: ready\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-l\tident-l\t4\t0\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$manifest"
  out="$dir/out"; err="$dir/err"

  run_retire "$state" task-l "$out" "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a symlinked manifest did not fail closed (rc=$rc)"
  grep -qF "$manifest" "$err" \
    || fail "a symlinked manifest failed with no diagnostic naming it: $(cat "$err")"
  grep -qi 'regular file' "$err" \
    || fail "the diagnostic did not name the reason (not a regular file): $(cat "$err")"
  [ -f "$f" ] || fail "an unusable manifest must never cause the status file to be deleted"
  [ -L "$manifest" ] || fail "an unusable manifest must be left exactly as found"
  pass "a symlinked manifest fails closed with a stderr line naming the file and reason, deleting nothing"
}

test_symlinked_manifest_is_loud_for_the_cursor_reader_too() {
  local dir state f manifest err rc=0
  dir=$(case_dir symlinked-manifest-reader)
  state="$dir/state"
  f="$state/task-m.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-m\tident-m\t4\t0\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$manifest"
  err="$dir/err"

  status_presentation_cursor_offset "$f" > /dev/null 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "the cursor reader accepted a symlinked manifest (rc=$rc)"
  grep -qF "$manifest" "$err" \
    || fail "the cursor reader gave no diagnostic for a symlinked manifest: $(cat "$err")"
  pass "the cursor reader also names an unusable manifest file on stderr instead of returning 1 in silence"
}

# The remote-home retire path validates the manifest twice (once unlocked to
# prove there is nothing to retire, once under the lock to rewrite it). One
# malformed row must still read as one finding for the operator.
test_a_malformed_row_is_reported_only_once() {
  local dir state manifest out err rc=0 count
  dir=$(case_dir single-diagnostic)
  state="$dir/state"
  manifest="$state/.status-presentation-cursor"
  printf 'task-other\tident-o\t1\t0\tstray\n' > "$manifest"
  out="$dir/out"; err="$dir/err"

  run_retire "$state" task-ghost "$out" "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "retiring a task with no status log over a malformed manifest did not fail closed (rc=$rc)"
  count=$(grep -c 'malformed status-presentation-cursor row' "$err") || count=0
  [ "$count" -eq 1 ] \
    || fail "one malformed row produced $count diagnostics, not 1: $(cat "$err")"
  [ -f "$manifest" ] || fail "a malformed manifest must never be deleted outright"
  pass "one malformed row is reported exactly once, even on the path that validates the manifest twice"
}

# An offset or backstop made of digits and colons ("1:2", "::") is not a byte
# offset. Validating both columns as one ":"-joined string let such a value
# through, so the cursor reader returned it verbatim with rc=0 and the backstop
# reader degraded to 0 - both without the promised diagnostic.
test_colon_in_offset_fails_loudly_like_any_non_numeric_offset() {
  local dir state f manifest err out rc=0
  dir=$(case_dir colon-in-offset)
  state="$dir/state"
  f="$state/task-n.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-n\tident-n\t1:2\t0\n' > "$manifest"
  err="$dir/err"; out="$dir/out"

  status_presentation_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "an offset with an embedded colon did not fail closed (rc=$rc, offset=$(cat "$out"))"
  [ -z "$(cat "$out")" ] || fail "a malformed offset was still handed to the caller: $(cat "$out")"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'non-numeric' "$err" \
    || fail "the error did not name the reason (non-numeric offset): $(cat "$err")"
  grep -qi 'integer expression expected' "$err" \
    && fail "a raw bash arithmetic error leaked instead of the manifest diagnostic: $(cat "$err")"
  pass "an offset with an embedded colon fails closed with the same diagnostic as any other non-numeric offset"
}

test_colon_in_backstop_fails_loudly_instead_of_degrading_to_zero() {
  local dir state f manifest err out rc=0
  dir=$(case_dir colon-in-backstop)
  state="$dir/state"
  f="$state/task-o.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-o\tident-o\t0\t3:4\n' > "$manifest"
  err="$dir/err"; out="$dir/out"

  status_outcome_backstop_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a backstop with an embedded colon did not fail closed (rc=$rc, backstop=$(cat "$out"))"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'non-numeric' "$err" \
    || fail "the error did not name the reason (non-numeric backstop): $(cat "$err")"
  pass "a backstop with an embedded colon fails closed loudly instead of silently degrading to 0"
}

# The locked rewrite loop's append was the last silent rc=1 at the manifest:
# a full disk or quota left bin/fm-teardown.sh exiting 1 with an empty stderr,
# the exact reported symptom. The child creates the symlink at the very path
# the function will use as its rewrite file, so writing a carried-over row
# fails with ENOSPC while creating/truncating that file still succeeds.
run_retire_with_failing_rewrite() {  # <state> <task> <out> <err>
  local state=$1 task=$2 out=$3 err=$4 rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    # shellcheck disable=SC1090,SC1091
    . "$2"
    ln -s /dev/full "$3/.status-presentation-cursor.tmp.$$" || exit 99
    status_retire_presentation_task "$3" "$4"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-classify-lib.sh" "$state" "$task" \
    > "$out" 2> "$err" || rc=$?
  return "$rc"
}

test_retire_reports_a_failed_rewrite_write_instead_of_failing_silently() {
  local dir state f other manifest ident out err rc=0
  [ -c /dev/full ] || { echo "skip: /dev/full not available"; return 0; }
  dir=$(case_dir retire-rewrite-write-failure)
  state="$dir/state"
  f="$state/task-p.status"
  other="$state/task-q.status"
  printf 'done: ready\n' > "$f"
  printf 'working: still here\n' > "$other"
  ident=$(file_ident "$f") || fail "could not compute a fixture ident"
  manifest="$state/.status-presentation-cursor"
  { printf 'task-p\t%s\t4\t0\n' "$ident"; printf 'task-q\tident-q\t2\t0\n'; } > "$manifest"
  out="$dir/out"; err="$dir/err"

  run_retire_with_failing_rewrite "$state" task-p "$out" "$err" && rc=0 || rc=$?
  [ "$rc" -ne 99 ] || fail "could not stage the failing rewrite file"
  [ "$rc" -eq 1 ] || fail "a failed rewrite write did not fail closed (rc=$rc): $(cat "$err")"
  grep -qF "$manifest" "$err" \
    || fail "a failed rewrite write produced no diagnostic naming the manifest: $(cat "$err")"
  grep -qi 'rewrite file' "$err" \
    || fail "the error did not name the rewrite file as the reason: $(cat "$err")"
  [ -f "$f" ] || fail "a failed rewrite must not delete the retired task's status file"
  grep -qF 'task-q' "$manifest" \
    || fail "a failed rewrite must leave the original manifest untouched: $(cat "$manifest")"
  pass "a rewrite file that cannot be written names the manifest on stderr instead of returning 1 in silence"
}

# A manifest path that is a symlink to a path that does not exist. `-e`
# follows the link, so the backstop reader's "no manifest yet" fast path
# claimed this state and returned backstop 0 with rc=0 - a wrong value with no
# diagnostic, which bin/fm-wake-drain.sh then treats as "nothing acknowledged"
# and status_commit_presentation_snapshot writes back as the backstop column.
test_dangling_symlink_manifest_is_loud_for_the_backstop_reader() {
  local dir state f manifest err out rc=0
  dir=$(case_dir dangling-symlink-manifest)
  state="$dir/state"
  f="$state/task-r.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  ln -s "$dir/never-created" "$manifest"
  err="$dir/err"; out="$dir/out"

  status_outcome_backstop_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "the backstop reader accepted a dangling symlink manifest (rc=$rc, backstop=$(cat "$out"))"
  grep -qF "$manifest" "$err" \
    || fail "a dangling symlink manifest produced no diagnostic naming the file: $(cat "$err")"
  pass "the backstop reader also fails closed loudly on a manifest symlink whose target does not exist"
}

# An offset made only of digits still passes a digits-only check while being
# far too wide for shell integer comparison: `[ "$offset" -gt "$size" ]` then
# aborts with "integer expression expected" instead of comparing, the clamp to
# 0 never runs, and the reader hands the unusable value back with rc=0.
test_out_of_range_offset_fails_loudly_like_any_non_numeric_offset() {
  local dir state f manifest err out rc=0
  dir=$(case_dir out-of-range-offset)
  state="$dir/state"
  f="$state/task-s.status"
  printf 'needs-decision: pick one\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-s\tident-s\t9999999999999999999999999\t0\n' > "$manifest"
  err="$dir/err"; out="$dir/out"

  status_presentation_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "an out-of-range offset did not fail closed (rc=$rc, offset=$(cat "$out"))"
  [ -z "$(cat "$out")" ] || fail "an out-of-range offset was still handed to the caller: $(cat "$out")"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'wider than 18 digits' "$err" \
    || fail "the error did not name the rule the value broke (digit width): $(cat "$err")"
  grep -qi 'non-numeric' "$err" \
    && fail "a numeric but too-wide offset was reported as non-numeric: $(cat "$err")"
  grep -qi 'integer expression expected' "$err" \
    && fail "a raw bash arithmetic error leaked instead of the manifest diagnostic: $(cat "$err")"
  pass "an offset too wide for shell integer comparison fails closed naming the digit-width rule, not \"non-numeric\""
}

test_out_of_range_backstop_fails_loudly_instead_of_degrading_to_zero() {
  local dir state f manifest err out rc=0
  dir=$(case_dir out-of-range-backstop)
  state="$dir/state"
  f="$state/task-t.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-t\tident-t\t5\t9999999999999999999999999\n' > "$manifest"
  err="$dir/err"; out="$dir/out"

  status_outcome_backstop_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "an out-of-range backstop did not fail closed (rc=$rc, backstop=$(cat "$out"))"
  grep -qi 'wider than 18 digits' "$err" \
    || fail "the error did not name the rule the value broke (digit width): $(cat "$err")"
  grep -qi 'integer expression expected' "$err" \
    && fail "a raw bash arithmetic error leaked instead of the manifest diagnostic: $(cat "$err")"
  pass "a backstop too wide for shell integer comparison fails closed loudly instead of silently degrading to 0"
}

# A leading zero makes the two consumers of the same field disagree:
# `[ "$offset" -lt "$size" ]` reads "010" as decimal 10, while the
# `$((size - offset))` beside it reads it as octal 8, so the span length and
# the span start no longer describe the same byte range.
test_leading_zero_offset_fails_loudly() {
  local dir state f manifest err out rc=0
  dir=$(case_dir leading-zero-offset)
  state="$dir/state"
  f="$state/task-u.status"
  printf 'needs-decision: pick one\nnote: hello\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-u\tident-u\t010\t0\n' > "$manifest"
  err="$dir/err"; out="$dir/out"

  status_presentation_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "an offset with a leading zero did not fail closed (rc=$rc, offset=$(cat "$out"))"
  [ -z "$(cat "$out")" ] || fail "an offset with a leading zero was still handed to the caller: $(cat "$out")"
  grep -qF "$manifest:1:" "$err" \
    || fail "the error did not name the manifest and line number: $(cat "$err")"
  grep -qi 'leading zero' "$err" \
    || fail "the error did not name the rule the value broke (leading zero): $(cat "$err")"
  grep -qi 'non-numeric' "$err" \
    && fail "a numeric offset with a leading zero was reported as non-numeric: $(cat "$err")"
  pass "an offset with a leading zero fails closed naming the leading-zero rule, not \"non-numeric\""
}

# A plain "0" is the ordinary value of both columns and must stay valid.
test_zero_offset_and_backstop_stay_valid() {
  local dir state f manifest ident out err rc=0
  dir=$(case_dir zero-offset-backstop)
  state="$dir/state"
  f="$state/task-v.status"
  printf 'working: setup\n' > "$f"
  ident=$(file_ident "$f") || fail "could not compute a fixture ident"
  manifest="$state/.status-presentation-cursor"
  printf 'task-v\t%s\t0\t0\n' "$ident" > "$manifest"
  out="$dir/out"; err="$dir/err"

  status_presentation_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a plain 0 offset was rejected (rc=$rc): $(cat "$err")"
  [ "$(cat "$out")" = 0 ] || fail "a plain 0 offset did not read back as 0: $(cat "$out")"
  status_outcome_backstop_cursor_offset "$f" > "$out" 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a plain 0 backstop was rejected (rc=$rc): $(cat "$err")"
  [ "$(cat "$out")" = 0 ] || fail "a plain 0 backstop did not read back as 0: $(cat "$out")"
  pass "a plain 0 stays a valid offset and backstop under the canonical-decimal rule"
}

# A row diagnostic has to state the format the operator should restore, not
# only the reason this row broke it - and the offset rule is part of that
# format, not just the column count.
test_row_diagnostic_states_the_offset_format_rule() {
  local dir state f manifest err rc=0
  dir=$(case_dir offset-format-in-diagnostic)
  state="$dir/state"
  f="$state/task-w.status"
  printf 'working: setup\n' > "$f"
  manifest="$state/.status-presentation-cursor"
  printf 'task-w\tident-w\tNaN\t0\n' > "$manifest"
  err="$dir/err"

  status_presentation_cursor_offset "$f" > /dev/null 2> "$err" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a non-numeric offset did not fail closed (rc=$rc)"
  grep -qF 'task, ident, offset, backstop' "$err" \
    || fail "the error dropped the expected column list: $(cat "$err")"
  grep -qi 'without a leading zero' "$err" \
    || fail "the expected format did not state the offset canonical-form rule: $(cat "$err")"
  grep -qi '18 digits' "$err" \
    || fail "the expected format did not state the offset digit limit: $(cat "$err")"
  pass "a row diagnostic states the offset and backstop format rule alongside the expected column list"
}

test_extra_column_fails_loudly_and_names_the_row
test_missing_field_fails_loudly_and_names_the_row
test_non_numeric_offset_fails_loudly_and_names_the_row
test_a_malformed_row_for_another_task_still_blocks_this_lookup
test_the_reported_four_field_row_is_valid_today
test_teardown_retire_surfaces_the_error_and_deletes_nothing
test_teardown_retire_succeeds_on_a_well_formed_manifest
test_extra_column_behind_an_empty_field_fails_loudly
test_retire_never_drops_a_column_behind_an_empty_field
test_legacy_three_field_row_is_read_and_upgraded_losslessly
test_retire_upgrades_a_legacy_three_field_row_of_another_task
test_symlinked_manifest_fails_loudly_and_deletes_nothing
test_symlinked_manifest_is_loud_for_the_cursor_reader_too
test_a_malformed_row_is_reported_only_once
test_colon_in_offset_fails_loudly_like_any_non_numeric_offset
test_colon_in_backstop_fails_loudly_instead_of_degrading_to_zero
test_retire_reports_a_failed_rewrite_write_instead_of_failing_silently
test_dangling_symlink_manifest_is_loud_for_the_backstop_reader
test_out_of_range_offset_fails_loudly_like_any_non_numeric_offset
test_out_of_range_backstop_fails_loudly_instead_of_degrading_to_zero
test_leading_zero_offset_fails_loudly
test_zero_offset_and_backstop_stay_valid
test_row_diagnostic_states_the_offset_format_rule
