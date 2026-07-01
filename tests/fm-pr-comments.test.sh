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
  printf 'MESSAGE<<EOF\n%s\nEOF\n' "$2"
} >> "$FAKE_SEND_LOG"
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
test_disable_cleans_check_shim
