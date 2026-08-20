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
#   (e) a note carrying a newline, tab, or escape is refused rather than trimmed
#   (e2) an ordinary non-ASCII note is accepted, stored verbatim, and bounded by
#        characters rather than by the bytes a UTF-8 sequence occupies
#   (f) a missing task metadata file is refused
#   (g) an unsafe task id never constructs a path
#   (h) fm-pr-check.sh's own metadata rewrite preserves the record
#   (i) re-recording while a merge poll is armed keeps that poll's metadata valid
#   (j) any well-formed key a later writer appends after pr= keeps that armed
#       poll valid, including one this parser has never seen, while a line that
#       is not a record line at all still invalidates the record
#   (k) an interrupted write leaves no temp file, no held lock, and no partial
#       record behind
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

# Ask the watcher's own validator whether this task's armed merge poll still
# holds, which is the consumer that revalidates a record after it is rewritten.
poll_artifacts_valid() {
  local case_dir=$1
  (
    # shellcheck source=bin/fm-pr-lib.sh
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_poll_artifacts_valid "$case_dir/state" task-e1 "$ROOT/bin/fm-pr-poll.sh"
  )
}

# Arm a merge poll the way bin/fm-pr-check.sh is run when a PR is reported.
# Args: case_dir head_sha pr_url
arm_merge_poll() {
  local case_dir=$1 head=$2 url=$3
  mkdir -p "$case_dir/fakebin" "$case_dir/wt"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-e1 "$url" > /dev/null
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

test_refuses_control_character_notes() {
  local case_dir rc label bad
  case_dir=$(make_case bad-note)

  # A newline splits the record outright; a tab or an escape survives into a
  # refusal message that is printed to a terminal. All three are control
  # characters, which is exactly what the refusal now claims it refuses.
  for label in newline tab escape; do
    case "$label" in
      newline) bad=$(printf 'suite pass\nevidence_head=%s' "$SHA_B") ;;
      tab) bad=$(printf 'suite\tpass') ;;
      *) bad=$(printf 'suite \033[31mpass') ;;
    esac
    set +e
    run_record "$case_dir" task-e1 "$SHA_A" "$bad" > "$case_dir/out" 2> "$case_dir/err"
    rc=$?
    set -e

    expect_code 2 "$rc" "bad-note: a note carrying a $label should be refused"
    assert_grep 'no control characters' "$case_dir/err" \
      "bad-note: the $label refusal did not state the note contract"
    assert_grep 'non-ASCII text such as an em dash is accepted' "$case_dir/err" \
      "bad-note: the $label refusal did not say what IS accepted, which is how a worker learns the constraint"
    assert_no_grep 'evidence_head=' "$case_dir/state/task-e1.meta" \
      "bad-note: a refused $label note still reached the metadata"
  done
  pass "fm-evidence-record.sh refuses a note that could split the record or drive the terminal"
}

# Workers write notes in ordinary prose, and ordinary prose carries an em dash or
# an accented word. A guard that refuses valid work is worked around rather than
# fixed, so a non-ASCII note is accepted, stored byte for byte, and read back by
# the merge guard exactly as written - and the length bound counts characters,
# not the bytes a UTF-8 sequence happens to occupy.
test_accepts_non_ascii_note() {
  local case_dir note got long rc
  case_dir=$(make_case unicode-note)
  note='suite 4208 pass — café exploit blocked ✅'

  run_record "$case_dir" task-e1 "$SHA_A" "$note" > /dev/null \
    || fail "unicode-note: a note carrying ordinary non-ASCII punctuation was refused"
  got=$(read_back "$case_dir/state/task-e1.meta") \
    || fail "unicode-note: the merge guard's reader rejected a non-ASCII note it had just written"
  [ "$got" = "$SHA_A|$note" ] || fail "unicode-note: the guard read '$got'"

  # 200 em dashes are 600 bytes but 200 characters, so a byte bound would refuse
  # a note the refusal message calls acceptable.
  long=$(awk 'BEGIN { while (i++ < 200) printf "%s", "\342\200\224" }')
  run_record "$case_dir" task-e1 "$SHA_B" "$long" > /dev/null \
    || fail "unicode-note: a 200-character note was refused by a byte-counting bound"

  set +e
  run_record "$case_dir" task-e1 "$SHA_B" "${long}—" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 2 "$rc" "unicode-note: a 201-character note should still be refused"
  assert_grep 'at most 200 characters' "$case_dir/err" \
    "unicode-note: the length refusal did not state the bound it enforces"
  pass "fm-evidence-record.sh accepts a non-ASCII note and bounds it by characters, as its refusal says"
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
  local case_dir
  case_dir=$(make_case survives-pr-check)

  run_record "$case_dir" task-e1 "$SHA_A" 'full suite 4208 pass' > /dev/null \
    || fail "survives-pr-check: record failed"
  arm_merge_poll "$case_dir" "$SHA_A" https://github.com/example/repo/pull/7 \
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
  poll_artifacts_valid "$case_dir" \
    || fail "survives-pr-check: re-recording evidence invalidated the armed merge poll"
  pass "the evidence record survives arming a merge poll and re-recording against an armed task"
}

# The evidence keys are not the only ones a legitimate writer appends after pr=.
# Relaunching a crewmate to address review comments rewrites the same record:
# bin/fm-spawn.sh strips and re-appends traceparent= at the end when trace
# context is on, and appends control_relaunch_tx= after the preserved pr= line,
# and bin/fm-decision-hold.sh appends its review record there too. Enumerating
# those keys was wrong three times running, so the parse tolerates any
# well-formed key=value line instead. The key below is deliberately one no
# writer emits and the parser has never seen: this assertion is the regression
# the tolerant shape exists for, and it fails against an allowlist.
test_unrecognised_appended_keys_keep_the_armed_poll_valid() {
  local case_dir meta
  case_dir=$(make_case relaunch-keys)
  meta="$case_dir/state/task-e1.meta"

  run_record "$case_dir" task-e1 "$SHA_A" 'full suite 4208 pass' > /dev/null \
    || fail "relaunch-keys: record failed"
  arm_merge_poll "$case_dir" "$SHA_A" https://github.com/example/repo/pull/11 \
    || fail "relaunch-keys: arming the merge poll failed"
  poll_artifacts_valid "$case_dir" \
    || fail "relaunch-keys: the freshly armed merge poll was already invalid"

  printf 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01\n' >> "$meta"
  poll_artifacts_valid "$case_dir" \
    || fail "relaunch-keys: a relaunch-recorded traceparent invalidated the armed merge poll"
  printf 'control_relaunch_tx=tx-2026-08-19-1\n' >> "$meta"
  poll_artifacts_valid "$case_dir" \
    || fail "relaunch-keys: a control relaunch transaction invalidated the armed merge poll"
  printf 'decisions_reviewed=1\ndecision_keys=stale-evidence\n' >> "$meta"
  poll_artifacts_valid "$case_dir" \
    || fail "relaunch-keys: a decision-hold review record invalidated the armed merge poll"

  # The fourth appender this parser has never been taught about. Nothing writes
  # this key; that is the point. A future writer must not silently become a
  # refused merge on valid work.
  printf 'some_future_writer_key=whatever it records\n' >> "$meta"
  poll_artifacts_valid "$case_dir" \
    || fail "relaunch-keys: a key the parser has never seen invalidated the armed merge poll"
  pass "a key the parser has never seen keeps an armed merge poll valid"
}

# Tolerating an unknown key must not become tolerating an unparsable record.
# These are the shapes a value carrying an embedded newline injects, and they
# are what the positional check after pr= still exists to catch.
test_malformed_lines_after_pr_still_invalidate_the_record() {
  local case_dir meta base

  for base in bare-fragment empty-line no-key leading-space second-pr; do
    case_dir=$(make_case "malformed-$base")
    meta="$case_dir/state/task-e1.meta"
    run_record "$case_dir" task-e1 "$SHA_A" 'full suite 4208 pass' > /dev/null \
      || fail "malformed-$base: record failed"
    arm_merge_poll "$case_dir" "$SHA_A" https://github.com/example/repo/pull/12 \
      || fail "malformed-$base: arming the merge poll failed"
    poll_artifacts_valid "$case_dir" \
      || fail "malformed-$base: the freshly armed merge poll was already invalid"

    case "$base" in
      bare-fragment) printf 'https://github.com/attacker/repo/pull/99\n' >> "$meta" ;;
      empty-line)    printf '\n' >> "$meta" ;;
      no-key)        printf '=orphaned value\n' >> "$meta" ;;
      leading-space) printf ' window=indented\n' >> "$meta" ;;
      second-pr)     printf 'pr=https://github.com/attacker/repo/pull/99\n' >> "$meta" ;;
    esac

    if poll_artifacts_valid "$case_dir"; then
      fail "malformed-$base: a malformed line after pr= was accepted"
    fi
  done
  pass "a fragment, an empty line, a keyless line, an indented line, and a second pr= after pr= all still invalidate the record"
}

# bin/fm-pr-check.sh, the other writer of this record, cleans up its temp file
# and releases the per-task lock when it is interrupted. This writer must behave
# the same way, or an interrupted recording leaves a stray temp beside the
# metadata and a lock the next writer has to wait out through stale-owner
# recovery. The shimmed grep signals the recorder inside the exact window: after
# mktemp created the temp, before the record is moved into place.
test_interrupted_write_leaves_no_temp_or_held_lock() {
  local case_dir meta lock real_grep leftover rc
  case_dir=$(make_case interrupted)
  meta="$case_dir/state/task-e1.meta"
  lock="$case_dir/state/.meta-task-e1.lock"
  real_grep=$(command -v grep)
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/grep" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"^evidence_head=|^evidence_note="*)
    if [ ! -e "$case_dir/signalled" ]; then
      : > "$case_dir/signalled"
      kill -TERM "\$PPID" 2>/dev/null || true
    fi
    ;;
esac
exec $real_grep "\$@"
SH
  chmod +x "$case_dir/fakebin/grep"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$RECORD" task-e1 "$SHA_A" 'full suite 4208 pass' > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "interrupted: an interrupted recording reported success"
  assert_present "$case_dir/signalled" \
    "interrupted: the recorder was never signalled mid-write"
  leftover=$(find "$case_dir/state" -name '.task-e1.meta.fm-evidence.*' | head -1)
  [ -z "$leftover" ] || fail "interrupted: a temp file was left behind: $leftover"
  { [ ! -e "$lock" ] && [ ! -L "$lock" ]; } \
    || fail "interrupted: the per-task metadata lock was left held"
  assert_grep 'kind=ship' "$meta" "interrupted: the task metadata was damaged"
  assert_no_grep 'evidence_head=' "$meta" \
    "interrupted: a partial record reached the metadata"

  # The lock is free, so the next recording completes without waiting on
  # another process's stale-owner recovery.
  run_record "$case_dir" task-e1 "$SHA_B" 'full suite 4212 pass' > /dev/null \
    || fail "interrupted: a later recording could not take the lock"
  assert_grep "evidence_head=$SHA_B" "$meta" \
    "interrupted: the later recording did not land"
  pass "an interrupted recording leaves no temp file, no held lock, and no partial record"
}

test_records_and_preserves_other_meta
test_re_measurement_replaces_the_record
test_record_reads_back_through_the_guard_helper
test_refuses_malformed_commit
test_refuses_control_character_notes
test_accepts_non_ascii_note
test_refuses_missing_and_unsafe_tasks
test_record_survives_pr_metadata_rewrite
test_unrecognised_appended_keys_keep_the_armed_poll_valid
test_malformed_lines_after_pr_still_invalidate_the_record
test_interrupted_write_leaves_no_temp_or_held_lock
