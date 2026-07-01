#!/usr/bin/env bash
# Behavior tests for PR comment watching: enable/disable creates the portable
# check shim, polling primes existing PR feedback, and new GitHub comments/review
# comments are deduped and delivered to the task via fm-send.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-pr-comments-tests)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = api ] && [ "${2:-}" = user ]; then
  printf '%s\n' "${FAKE_GH_USER:-firstmate}"
  exit 0
fi
if [ "$1" = api ]; then
  [ "${FAKE_GH_FAIL:-0}" = 0 ] || exit 1
  endpoint=
  for arg in "$@"; do
    case "$arg" in /repos/*) endpoint=$arg ;; esac
  done
  case "$endpoint" in
    */issues/*/comments) [ -n "${FAKE_ISSUE_COMMENTS:-}" ] && cat "$FAKE_ISSUE_COMMENTS" ;;
    */pulls/*/comments) [ -n "${FAKE_REVIEW_COMMENTS:-}" ] && cat "$FAKE_REVIEW_COMMENTS" ;;
    */pulls/*/reviews) [ -n "${FAKE_REVIEWS:-}" ] && cat "$FAKE_REVIEWS" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/fake-send" <<'SH'
#!/usr/bin/env bash
{
  printf 'TARGET=%s\n' "$1"
  case "$2" in *$'\n'*) printf 'HAS_NEWLINE=1\n' ;; *) printf 'HAS_NEWLINE=0\n' ;; esac
  printf 'MESSAGE<<EOF\n%s\nEOF\n' "$2"
} >> "$FAKE_SEND_LOG"
[ "${FAKE_SEND_FAIL:-0}" = 0 ] || exit 1
SH
  chmod +x "$fakebin/fake-send"
  printf '%s\n' "$fakebin"
}

write_event_files() {
  local dir=$1
  : > "$dir/issue.jsonl"
  : > "$dir/review-comments.jsonl"
  : > "$dir/reviews.jsonl"
}

make_home_with_pr_task() {
  local home=$1
  mkdir -p "$home/state"
  fm_write_meta "$home/state/maps.meta" \
    "window=fm-maps" \
    "project=maps" \
    "kind=ship" \
    "pr=https://github.com/acme/maps/pull/7"
}

test_enable_primes_and_dedupes_new_issue_comment() {
  local home fakebin send_log out rc
  home="$TMP_ROOT/prime-dedupe"; mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  write_event_files "$home"
  make_home_with_pr_task "$home"
  send_log="$home/send.log"
  printf '%s\n' '{"type":"issue_comment","id":"100","author":"reviewer","url":"https://github.com/acme/maps/pull/7#issuecomment-100","path":"","line":"","state":"","body":"existing feedback"}' > "$home/issue.jsonl"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments.sh" enable all 2>/dev/null); rc=$?
  expect_code 0 "$rc" "enable all exit"
  assert_contains "$out" "enabled: PR comment watching for all PR-linked tasks" "enable must report all scope"
  assert_present "$home/state/pr-comments.check.sh" "enable all must create the check shim"
  assert_absent "$send_log" "enable must prime existing comments without sending them"
  assert_grep "issue_comment:100" "$home/state/.pr-comments/seen/maps.seen" "prime must persist existing comment id"

  printf '%s\n' \
    '{"type":"issue_comment","id":"100","author":"reviewer","url":"https://github.com/acme/maps/pull/7#issuecomment-100","path":"","line":"","state":"","body":"existing feedback"}' \
    '{"type":"issue_comment","id":"101","author":"reviewer","url":"https://github.com/acme/maps/pull/7#issuecomment-101","path":"","line":"","state":"","body":"please adjust the legend"}' \
    > "$home/issue.jsonl"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments-poll.sh" --enabled); rc=$?
  expect_code 0 "$rc" "poll enabled exit"
  [ -z "$out" ] || fail "successful injected comment poll should be silent (got: $out)"
  assert_grep "TARGET=fm-maps" "$send_log" "poll must deliver to the task window"
  assert_grep "PR issue comment" "$send_log" "poll must label issue comments"
  assert_grep "please adjust the legend" "$send_log" "poll must include the comment body"
  assert_grep "issue_comment:101" "$home/state/.pr-comments/seen/maps.seen" "poll must persist the new id after send"
  before=$(wc -l < "$send_log" | tr -d ' ')
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments-poll.sh" --enabled >/dev/null
  after=$(wc -l < "$send_log" | tr -d ' ')
  [ "$before" = "$after" ] || fail "second poll must not inject duplicates"
  pass "PR comment watching primes old comments and dedupes new issue comments"
}

test_review_comment_context_and_bot_ignore() {
  local home fakebin send_log rc
  home="$TMP_ROOT/review-context"; mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  write_event_files "$home"
  make_home_with_pr_task "$home"
  send_log="$home/send.log"
  mkdir -p "$home/state/.pr-comments/enabled"
  : > "$home/state/.pr-comments/enabled/maps"
  printf '%s\n' \
    '{"type":"review_comment","id":"200","author":"github-actions[bot]","url":"https://github.com/acme/maps/pull/7#discussion_r200","path":"src/map.ts","line":"42","state":"","body":"bot noise"}' \
    '{"type":"review_comment","id":"201","author":"reviewer","url":"https://github.com/acme/maps/pull/7#discussion_r201","path":"src/map.ts","line":"43","state":"","body":"extract this helper"}' \
    > "$home/review-comments.jsonl"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments-poll.sh" --enabled >/dev/null; rc=$?
  expect_code 0 "$rc" "review comment poll exit"
  assert_no_grep "bot noise" "$send_log" "bot comments must not be injected"
  assert_grep "PR review comment" "$send_log" "review comments must be labeled"
  assert_grep "Location: src/map.ts:43" "$send_log" "review comments must include file and line"
  assert_grep "extract this helper" "$send_log" "review comment body must be delivered"
  assert_grep "review_comment:200" "$home/state/.pr-comments/seen/maps.seen" "ignored bot comment must still be marked seen"
  pass "PR review comments include code context and bot noise is ignored"
}

test_multiline_feedback_is_single_line_and_clears_send_error() {
  local home fakebin send_log out rc err_marker
  home="$TMP_ROOT/single-line"; mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  write_event_files "$home"
  make_home_with_pr_task "$home"
  send_log="$home/send.log"
  mkdir -p "$home/state/.pr-comments/enabled"
  : > "$home/state/.pr-comments/enabled/maps"
  printf '%s\n' '{"type":"review_comment","id":"300","author":"reviewer","url":"https://github.com/acme/maps/pull/7#discussion_r300","path":"src/map.ts","line":"50","state":"","body":"first line\nsecond line\nthird line"}' > "$home/review-comments.jsonl"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_FAIL=1 FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments-poll.sh" --enabled); rc=$?
  expect_code 0 "$rc" "failed send poll exit"
  assert_contains "$out" "pr-comment-watch-error maps: failed to inject PR feedback" "send failures must surface once"
  assert_no_grep "review_comment:300" "$home/state/.pr-comments/seen/maps.seen" "failed sends must not mark the comment seen"
  err_marker="$home/state/.pr-comments/errors/maps-send"
  assert_present "$err_marker" "send failure marker must be recorded"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments-poll.sh" --enabled); rc=$?
  expect_code 0 "$rc" "successful retry poll exit"
  [ -z "$out" ] || fail "successful retry should be silent (got: $out)"
  assert_grep "HAS_NEWLINE=0" "$send_log" "PR feedback must be delivered as one line"
  assert_grep "Author: reviewer" "$send_log" "single-line feedback must preserve author"
  assert_grep "URL: https://github.com/acme/maps/pull/7#discussion_r300" "$send_log" "single-line feedback must preserve URL"
  assert_grep "Location: src/map.ts:50" "$send_log" "single-line feedback must preserve file and line"
  assert_grep "first line ⏎ second line ⏎ third line" "$send_log" "single-line feedback must preserve body context with separators"
  assert_grep "review_comment:300" "$home/state/.pr-comments/seen/maps.seen" "successful retry must mark the comment seen"
  assert_absent "$err_marker" "successful sends must clear the prior send error marker"
  pass "PR feedback injection is single-line and clears send errors"
}

test_stale_task_lock_is_recovered() {
  local home fakebin send_log lock rc
  home="$TMP_ROOT/stale-lock"; mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  write_event_files "$home"
  make_home_with_pr_task "$home"
  send_log="$home/send.log"
  lock="$home/state/.pr-comments/locks/maps.lock"
  mkdir -p "$home/state/.pr-comments/enabled" "$lock"
  : > "$home/state/.pr-comments/enabled/maps"
  printf 'malformed-owner\n' > "$lock/owner"
  touch -t 202001010000 "$lock"
  printf '%s\n' '{"type":"issue_comment","id":"400","author":"reviewer","url":"https://github.com/acme/maps/pull/7#issuecomment-400","path":"","line":"","state":"","body":"stale lock should not block this"}' > "$home/issue.jsonl"

  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FM_PR_COMMENTS_LOCK_STALE_SECS=1 FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments-poll.sh" --enabled >/dev/null; rc=$?
  expect_code 0 "$rc" "stale lock poll exit"
  assert_grep "stale lock should not block this" "$send_log" "stale locks must be reaped so feedback is delivered"
  assert_grep "issue_comment:400" "$home/state/.pr-comments/seen/maps.seen" "stale-lock delivery must mark the comment seen"
  assert_absent "$lock" "task lock must be cleaned up after polling"
  pass "PR comment polling recovers stale task locks"
}

test_prime_surfaces_github_poll_errors() {
  local home fakebin out rc
  home="$TMP_ROOT/prime-errors"; mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  write_event_files "$home"
  make_home_with_pr_task "$home"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$home/send.log" FAKE_GH_FAIL=1 FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments.sh" enable all 2>/dev/null); rc=$?
  expect_code 0 "$rc" "enable all with prime error exit"
  assert_contains "$out" "pr-comment-watch-error maps: GitHub comment poll failed" "enable priming must surface GitHub poll failures"
  assert_contains "$out" "enabled: PR comment watching for all PR-linked tasks" "enable should still report configured watching"
  pass "PR comment enabling surfaces priming poll errors"
}

test_disable_task_excludes_under_all_scope() {
  local home fakebin send_log out rc
  home="$TMP_ROOT/disable-under-all"; mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  write_event_files "$home"
  make_home_with_pr_task "$home"
  fm_write_meta "$home/state/roads.meta" \
    "window=fm-roads" \
    "project=roads" \
    "kind=ship" \
    "pr=https://github.com/acme/roads/pull/9"
  send_log="$home/send.log"

  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments.sh" enable all >/dev/null 2>/dev/null
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-pr-comments.sh" disable maps 2>/dev/null); rc=$?
  expect_code 0 "$rc" "disable task under all exit"
  assert_contains "$out" "disabled: PR comment watching for maps" "disable task under all must report the task"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-pr-comments.sh" status 2>/dev/null); rc=$?
  expect_code 0 "$rc" "status after exclusion exit"
  assert_contains "$out" "scope: all PR-linked tasks" "status must retain all scope"
  assert_contains "$out" "excluded: maps" "status must list per-task exclusions"

  printf '%s\n' '{"type":"issue_comment","id":"500","author":"reviewer","url":"https://github.com/acme/maps/pull/7#issuecomment-500","path":"","line":"","state":"","body":"all scope should skip maps only"}' > "$home/issue.jsonl"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$send_log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments-poll.sh" --enabled >/dev/null; rc=$?
  expect_code 0 "$rc" "poll enabled with excluded task exit"
  assert_no_grep "TARGET=fm-maps" "$send_log" "disabled task under all must not receive injected feedback"
  assert_grep "TARGET=fm-roads" "$send_log" "other all-scope tasks must still receive injected feedback"
  pass "PR comment watching supports per-task exclusions under all scope"
}

test_disable_cleans_check_shim() {
  local home fakebin out rc
  home="$TMP_ROOT/disable"; mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  write_event_files "$home"
  make_home_with_pr_task "$home"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PR_COMMENTS_SEND="$fakebin/fake-send" \
    FAKE_SEND_LOG="$home/send.log" FAKE_ISSUE_COMMENTS="$home/issue.jsonl" \
    FAKE_REVIEW_COMMENTS="$home/review-comments.jsonl" FAKE_REVIEWS="$home/reviews.jsonl" \
    "$ROOT/bin/fm-pr-comments.sh" enable maps >/dev/null 2>/dev/null
  assert_present "$home/state/pr-comments.check.sh" "task enable must create check shim"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-pr-comments.sh" disable all 2>/dev/null); rc=$?
  expect_code 0 "$rc" "disable all exit"
  assert_contains "$out" "disabled: PR comment watching" "disable must report success"
  assert_absent "$home/state/pr-comments.check.sh" "disable all must remove check shim"
  pass "PR comment watching disables cleanly"
}

test_enable_primes_and_dedupes_new_issue_comment
test_review_comment_context_and_bot_ignore
test_multiline_feedback_is_single_line_and_clears_send_error
test_stale_task_lock_is_recovered
test_prime_surfaces_github_poll_errors
test_disable_task_excludes_under_all_scope
test_disable_cleans_check_shim
