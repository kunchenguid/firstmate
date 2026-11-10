#!/usr/bin/env bash
# Behavior tests for bin/fm-review-check.sh, which records a review-ready
# forge=external task: exactly one review= and review_head=, no merge watch, and
# in a secondmate home the child's ready line on the parent channel. The
# fixtures use an invented review host under an RFC 6761 reserved name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-review-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-check)
fm_git_identity fmtest fmtest@example.invalid
URL='https://review.example.test/r/123'

# fixture <name> [meta-lines...]: a home with a worker copy and a task record.
# Sets HOME_DIR, WT, REPO, META.
fixture() {
  local name=$1
  shift
  HOME_DIR="$TMP_ROOT/$name/home"
  REPO="$TMP_ROOT/$name/repo"
  WT="$TMP_ROOT/$name/wt"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  fm_git_worktree "$REPO" "$WT" fm/t1
  git -C "$WT" commit -q --allow-empty -m 'change only in the copy'
  META="$HOME_DIR/state/t1.meta"
  fm_write_meta "$META" window=fm-t1 "worktree=$WT" "project=$REPO" kind=ship mode=direct-PR yolo=off \
    branch=fm/t1 unrelated=kept "$@"
}

run_check() {  # <args...>; sets OUT and RC
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$CHECK" "$@" 2>&1)
  RC=$?
}

test_records_one_review_and_no_watch() {
  local head
  fixture records forge=external
  head=$(git -C "$WT" rev-parse HEAD)
  run_check t1 "$URL"
  expect_code 0 "$RC" "recording a review failed: $OUT"
  [ "$(grep -c '^review=' "$META")" = 1 ] || fail "expected exactly one review= line"
  assert_grep "review=$URL" "$META" "the review URL was not recorded"
  assert_grep "review_head=$head" "$META" "the worker HEAD was not recorded"
  assert_grep 'unrelated=kept' "$META" "an unrelated meta line was lost"
  assert_no_grep 'pr=' "$META" "a review was recorded as a forge PR"
  assert_absent "$HOME_DIR/state/t1.check.sh" "a merge watch was armed for an external review"
  assert_absent "$HOME_DIR/state/t1.pr-poll" "a PR poll sidecar was written for an external review"
  git -C "$WT" commit -q --allow-empty -m 'second upload'
  run_check t1 'https://review.example.test/r/124'
  expect_code 0 "$RC" "re-recording a review failed: $OUT"
  [ "$(grep -c '^review=' "$META")" = 1 ] || fail "a re-record left more than one review= line"
  [ "$(grep -c '^review_head=' "$META")" = 1 ] || fail "a re-record left more than one review_head= line"
  assert_grep 'review=https://review.example.test/r/124' "$META" "a re-record did not replace the URL"
  assert_grep "review_head=$(git -C "$WT" rev-parse HEAD)" "$META" "a re-record did not replace the head"
  pass "fm-review-check: records one review= and review_head=, arms no watch, and a re-record replaces both"
}

test_refusals() {
  fixture refusals forge=external
  run_check t1 'https://github.com/o/r/pull/1'
  [ "$RC" -ne 0 ] || fail "a forge PR URL was recorded as a review"
  run_check t1 'http://review.example.test/r/1'
  [ "$RC" -ne 0 ] || fail "a non-https review URL was recorded"
  printf '%s\n' '^https://review\.example\.test/r/[1-9][0-9]*$' > "$HOME_DIR/config/external-review-url"
  run_check t1 'https://other.example.test/r/1'
  [ "$RC" -ne 0 ] || fail "a URL outside config/external-review-url was recorded"
  run_check t1 "$URL"
  expect_code 0 "$RC" "a URL matching config/external-review-url was refused: $OUT"
  run_check '../escape' "$URL"
  [ "$RC" -ne 0 ] || fail "an unsafe task id was accepted"
  run_check t1
  [ "$RC" -ne 0 ] || fail "a missing argument was accepted"
  run_check t2 "$URL"
  [ "$RC" -ne 0 ] || fail "a task with no meta was accepted"
  assert_contains "$OUT" "task metadata is unavailable" "the missing-meta refusal did not say why"

  fixture not-external
  run_check t1 "$URL"
  [ "$RC" -ne 0 ] || fail "a task without forge=external recorded a review"
  assert_contains "$OUT" "does not record forge=external" "the forge refusal did not say why"

  fixture backed-up forge=external backup_remote=backup backup_prefix=backup/
  run_check t1 "$URL"
  [ "$RC" -ne 0 ] || fail "a review was recorded before the backup copy held HEAD"
  assert_contains "$OUT" "not on the backup remote backup" "the backup refusal did not name the remote"
  git -C "$WT" update-ref refs/remotes/backup/backup/t1 "$(git -C "$WT" rev-parse HEAD)"
  run_check t1 "$URL"
  expect_code 0 "$RC" "a backed-up review was refused once the copy held HEAD: $OUT"
  pass "fm-review-check: refuses a forge PR, non-https, a pattern mismatch, an unsafe id, missing input, a non-external task, and an unbacked copy"
}

test_secondmate_home_publishes_the_ready_line() {
  fixture mate forge=external
  printf '%s\n' mate-x > "$HOME_DIR/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$HOME_DIR/.fm-secondmate-parent"
  run_check t1 "$URL"
  expect_code 0 "$RC" "recording in a secondmate home failed: $OUT"
  assert_grep "child t1 review ready: $URL" "$HOME_DIR/state/parent-replies.status" \
    "the child's review-ready line did not reach the parent channel"
  assert_grep "[key=child-review-t1]" "$HOME_DIR/state/parent-replies.status" \
    "the child's review-ready line lost its decision key"
  pass "fm-review-check: a secondmate home publishes the child's review-ready line to the parent channel"
}

test_records_one_review_and_no_watch
test_refusals
test_secondmate_home_publishes_the_ready_line

echo "# all fm-review-check tests passed"
