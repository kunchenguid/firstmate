#!/usr/bin/env bash
# Tests for bin/fm-evidence-record.sh: the only writer of the evidence record
# bin/fm-pr-merge.sh refuses stale merges against. The record has to survive
# every other metadata mutation, replace itself on re-measurement, and refuse
# anything that could put a wrong or unparsable claim into a task's metadata.
#
# Matrix:
#   (a) a record is written and reported, preserving every other meta line
#   (b) re-measuring replaces the record instead of stacking a second one
#   (c) the note is stored verbatim and read back by the merge guard's reader
#   (d) a short, uppercase, or non-hex commit is refused before any write
#   (e) a note carrying a newline is refused rather than silently trimmed
#   (f) a missing task metadata file is refused
#   (g) an unsafe task id never constructs a path
#   (h) fm-pr-check.sh's own metadata rewrite preserves the record
#   (i) re-recording while a merge poll is armed keeps that poll's metadata valid
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECORD="$ROOT/bin/fm-evidence-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-evidence-record-tests)
SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  fm_write_meta "$case_dir/state/task-e1.meta" \
    "window=fm-task-e1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

run_record() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$RECORD" "$@"
}

# Read the record back through the same helper bin/fm-pr-merge.sh uses, so the
# test asserts the guard's view of the metadata rather than its own parse of it.
read_back() {
  local meta=$1
  (
    # shellcheck source=bin/fm-pr-lib.sh
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_evidence_read "$meta" || exit 1
    printf '%s|%s\n' "$FM_PR_EVIDENCE_HEAD" "$FM_PR_EVIDENCE_NOTE"
  )
}

test_records_and_preserves_other_meta() {
  local case_dir out
  case_dir=$(make_case records)

  out=$(run_record "$case_dir" task-e1 "$SHA_A" 'full suite 4208 pass') \
    || fail "records: fm-evidence-record.sh failed"

  case "$out" in
    "recorded: task-e1 evidence measured on $SHA_A (full suite 4208 pass)") ;;
    *) fail "records: unexpected confirmation line: $out" ;;
  esac
  assert_grep "evidence_head=$SHA_A" "$case_dir/state/task-e1.meta" \
    "records: evidence_head was not written"
  assert_grep 'evidence_note=full suite 4208 pass' "$case_dir/state/task-e1.meta" \
    "records: evidence_note was not written"
  assert_grep 'kind=ship' "$case_dir/state/task-e1.meta" \
    "records: an unrelated meta line was lost"
  assert_grep 'mode=no-mistakes' "$case_dir/state/task-e1.meta" \
    "records: an unrelated meta line was lost"
  pass "fm-evidence-record.sh records the measured commit and preserves the rest of the metadata"
}

test_re_measurement_replaces_the_record() {
  local case_dir count
  case_dir=$(make_case re-measure)

  run_record "$case_dir" task-e1 "$SHA_A" 'full suite 4202 pass' > /dev/null \
    || fail "re-measure: first record failed"
  run_record "$case_dir" task-e1 "$SHA_B" 'full suite 4208 pass' > /dev/null \
    || fail "re-measure: second record failed"

  count=$(grep -c '^evidence_head=' "$case_dir/state/task-e1.meta")
  [ "$count" = 1 ] || fail "re-measure: expected exactly one evidence_head line, found $count"
  count=$(grep -c '^evidence_note=' "$case_dir/state/task-e1.meta")
  [ "$count" = 1 ] || fail "re-measure: expected exactly one evidence_note line, found $count"
  assert_grep "evidence_head=$SHA_B" "$case_dir/state/task-e1.meta" \
    "re-measure: the re-measured commit did not replace the earlier one"
  assert_no_grep "evidence_head=$SHA_A" "$case_dir/state/task-e1.meta" \
    "re-measure: the superseded commit is still recorded"
  pass "fm-evidence-record.sh replaces the record on re-measurement instead of stacking claims"
}

test_record_reads_back_through_the_guard_helper() {
  local case_dir got
  case_dir=$(make_case read-back)

  run_record "$case_dir" task-e1 "$SHA_A" 'injection exploit blocked' > /dev/null \
    || fail "read-back: record failed"
  got=$(read_back "$case_dir/state/task-e1.meta") \
    || fail "read-back: the merge guard's reader rejected a freshly written record"
  [ "$got" = "$SHA_A|injection exploit blocked" ] \
    || fail "read-back: the guard read '$got'"

  # An absent record is a readable no-record, distinct from a corrupt one.
  fm_write_meta "$case_dir/state/task-e2.meta" "kind=ship"
  got=$(read_back "$case_dir/state/task-e2.meta") \
    || fail "read-back: an absent record should read back cleanly as no record"
  [ "$got" = "|" ] || fail "read-back: an absent record read as '$got'"

  # A corrupt record must never read back as a match.
  printf 'evidence_head=not-a-sha\n' >> "$case_dir/state/task-e2.meta"
  read_back "$case_dir/state/task-e2.meta" > /dev/null 2>&1 \
    && fail "read-back: a malformed evidence_head was accepted"
  pass "fm-evidence-record.sh writes what the merge guard reads, and corruption never reads as a match"
}

test_refuses_malformed_commit() {
  local case_dir bad rc
  case_dir=$(make_case bad-sha)

  for bad in 1111111 "$(printf '%s' "$SHA_A" | tr 'a-f' 'A-F')zz" 'g111111111111111111111111111111111111111' ''; do
    set +e
    run_record "$case_dir" task-e1 "$bad" > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e
    expect_code 2 "$rc" "bad-sha: '$bad' should be refused"
    assert_grep 'is not a full commit SHA' "$case_dir/err" \
      "bad-sha: refusal for '$bad' did not say what a valid commit looks like"
  done
  assert_no_grep 'evidence_head=' "$case_dir/state/task-e1.meta" \
    "bad-sha: a refused commit still reached the metadata"
  pass "fm-evidence-record.sh refuses a commit that is not a full SHA, before writing anything"
}

test_refuses_multiline_note() {
  local case_dir rc
  case_dir=$(make_case bad-note)

  set +e
  run_record "$case_dir" task-e1 "$SHA_A" "$(printf 'suite pass\nevidence_head=%s' "$SHA_B")" \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 2 "$rc" "bad-note: a multi-line note should be refused"
  assert_grep 'one printable line' "$case_dir/err" \
    "bad-note: refusal did not state the note contract"
  assert_no_grep 'evidence_head=' "$case_dir/state/task-e1.meta" \
    "bad-note: a refused note still reached the metadata"
  pass "fm-evidence-record.sh refuses a note that could split the record it is stored in"
}

test_refuses_missing_and_unsafe_tasks() {
  local case_dir rc
  case_dir=$(make_case missing-task)

  set +e
  run_record "$case_dir" task-absent "$SHA_A" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing-task: an unknown task should be refused"
  assert_grep 'task metadata is unavailable' "$case_dir/err" \
    "missing-task: refusal did not explain the missing metadata"

  set +e
  run_record "$case_dir" ../escape "$SHA_A" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 2 "$rc" "unsafe-id: a path-unsafe task id should be refused"
  assert_grep 'invalid evidence record request' "$case_dir/err" \
    "unsafe-id: refusal was not the fixed, non-probing one"
  assert_absent "$case_dir/state/../escape.meta" \
    "unsafe-id: an unsafe task id constructed a path"
  pass "fm-evidence-record.sh refuses an unknown task and never builds a path from an unsafe id"
}

test_record_survives_pr_metadata_rewrite() {
  local case_dir fakebin
  case_dir=$(make_case survives-pr-check)
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin" "$case_dir/wt"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *headRefOid*) printf '%s\n' '$SHA_A' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"

  run_record "$case_dir" task-e1 "$SHA_A" 'full suite 4208 pass' > /dev/null \
    || fail "survives-pr-check: record failed"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-e1 https://github.com/example/repo/pull/7 > /dev/null \
    || fail "survives-pr-check: fm-pr-check.sh failed"

  assert_grep "evidence_head=$SHA_A" "$case_dir/state/task-e1.meta" \
    "survives-pr-check: arming the merge poll dropped the evidence record"
  assert_grep 'evidence_note=full suite 4208 pass' "$case_dir/state/task-e1.meta" \
    "survives-pr-check: arming the merge poll dropped the evidence note"

  # The refused-merge remedy is to re-measure and re-record, which happens while
  # the merge poll is already armed. That rewrite appends the evidence lines
  # after pr=, and the watcher revalidates the armed poll against this same
  # metadata, so the record has to stay a valid PR record in that arrangement.
  run_record "$case_dir" task-e1 "$SHA_B" 'full suite 4212 pass' > /dev/null \
    || fail "survives-pr-check: re-recording on an armed task failed"
  (
    # shellcheck source=bin/fm-pr-lib.sh
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_poll_artifacts_valid "$case_dir/state" task-e1 "$ROOT/bin/fm-pr-poll.sh"
  ) || fail "survives-pr-check: re-recording evidence invalidated the armed merge poll"
  pass "the evidence record survives arming a merge poll and re-recording against an armed task"
}

test_records_and_preserves_other_meta
test_re_measurement_replaces_the_record
test_record_reads_back_through_the_guard_helper
test_refuses_malformed_commit
test_refuses_multiline_note
test_refuses_missing_and_unsafe_tasks
test_record_survives_pr_metadata_rewrite
