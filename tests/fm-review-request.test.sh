#!/usr/bin/env bash
# Behavioral tests for bin/fm-review-request.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-review-request.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-request-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

HEAD=1111111111111111111111111111111111111111
POST_LOG="$TMP_ROOT/post.log"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  "api repos/o/r/pulls/7")
    pull=${FM_TEST_PULL_JSON-}
    if [ -z "$pull" ]; then
      pull='{"head":{"sha":"'"$FM_TEST_HEAD"'"},"draft":false}'
    fi
    printf '%s\n' "$pull"
    ;;
  "api repos/o/r --jq .default_branch")
    printf 'main\n'
    ;;
  "api repos/o/r/contents/.github/workflows/opencode.yml?ref=main --jq .path")
    if [ "${FM_TEST_NO_CALLER:-0}" = 1 ]; then
      printf 'gh: Not Found (HTTP 404)\n' >&2
      exit 1
    fi
    printf '.github/workflows/opencode.yml\n'
    ;;
  "api repos/o/r/commits/"*" --jq .commit.committer.date")
    printf '%s\n' "${FM_TEST_HEAD_TIME:-2026-10-09T09:00:00Z}"
    ;;
  "api repos/o/r/issues/7/comments?per_page=100 --paginate --slurp")
    printf '%s\n' "${FM_TEST_COMMENTS_JSON:-[[]]}"
    ;;
  "pr comment 7 --repo o/r --body /oc review")
    printf '%s\n' "$*" >> "${FM_TEST_POST_LOG:?}"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_request() {
  : > "$POST_LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_TEST_HEAD="$HEAD" \
    FM_TEST_POST_LOG="$POST_LOG" \
    "$SCRIPT" https://github.com/o/r/pull/7
}

posted_count() {
  [ -f "$POST_LOG" ] || { printf '0\n'; return; }
  awk 'END { print NR + 0 }' "$POST_LOG"
}

comment() { # <created_at> <body> -> one page containing one comment object
  jq -n --arg at "$1" --arg body "$2" \
    '{created_at:$at,user:{login:"opencode-agent[bot]"},body:$body}'
}

test_skips_when_no_caller_exists() {
  local out status=0
  : > "$POST_LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_TEST_HEAD="$HEAD" FM_TEST_NO_CALLER=1 FM_TEST_POST_LOG="$POST_LOG" \
    "$SCRIPT" https://github.com/o/r/pull/7 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "an absent caller must be skipped, not refused: rc=$status $out"
  assert_contains "$out" 'skipped: no OpenCode caller workflow' \
    "an absent caller must be reported plainly"
  [ "$(posted_count)" = 0 ] || fail "no request may be posted without a caller"
  pass 'an absent caller skips the request without posting'
}

test_requests_when_no_request_or_review_covers_head() {
  local out
  out=$(FM_TEST_COMMENTS_JSON='[[]]' run_request) || fail "an uncovered head was not requested: $out"
  assert_contains "$out" "requested /oc review on $HEAD https://github.com/o/r/pull/7" \
    "an uncovered head must be requested"
  [ "$(posted_count)" = 1 ] || fail "exactly one request comment must be posted"
  assert_contains "$(cat "$POST_LOG")" '/oc review' "the posted comment must be the review command"
  pass 'an uncovered head is requested exactly once'
}

test_skips_completed_review_covering_head() {
  local out
  out=$(FM_TEST_COMMENTS_JSON="[[$(comment 2026-10-09T09:05:00Z 'findings... <!-- oc-review: completed -->')]]" run_request) \
    || fail "a covered head was not skipped: $out"
  assert_contains "$out" 'skipped: a completed OpenCode review already covers' \
    "a completed review on the head must be reported"
  [ "$(posted_count)" = 0 ] || fail "no duplicate request may follow a completed review"
  pass 'a completed review covering the head skips the request'
}

test_skips_existing_request_covering_head() {
  local out
  out=$(FM_TEST_COMMENTS_JSON="[[$(comment 2026-10-09T09:02:00Z '/oc review')]]" run_request) \
    || fail "an already-requested head was not skipped: $out"
  assert_contains "$out" 'skipped: an OpenCode review is already requested' \
    "an existing request on the head must be reported"
  [ "$(posted_count)" = 0 ] || fail "a second request comment is a duplicate"
  pass 'an existing request covering the head skips the duplicate'
}

test_skips_relay_request_covering_head() {
  local out
  out=$(FM_TEST_COMMENTS_JSON="[[$(comment 2026-10-09T09:02:00Z 'requested by relay <!-- relay-auto-review: head -->')]]" run_request) \
    || fail "a relay-requested head was not skipped: $out"
  assert_contains "$out" 'skipped: an OpenCode review is already requested' \
    "a relay request on the head must count as an existing request"
  [ "$(posted_count)" = 0 ] || fail "a relay request must not be duplicated"
  pass 'a relay review request covering the head skips the duplicate'
}

test_requests_again_after_new_head() {
  local out
  out=$(FM_TEST_COMMENTS_JSON="[[$(comment 2026-10-09T08:00:00Z 'old review <!-- oc-review: completed -->')]]" run_request) \
    || fail "a new head after a review was not requested: $out"
  assert_contains "$out" "requested /oc review on $HEAD" \
    "a head pushed after the last review must be requested anew"
  [ "$(posted_count)" = 1 ] || fail "a new head must produce exactly one request"
  pass 'a new head after a review is requested again'
}

test_skips_draft() {
  local out pull
  pull=$(jq -n --arg head "$HEAD" '{head:{sha:$head},draft:true}')
  : > "$POST_LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_TEST_HEAD="$HEAD" FM_TEST_PULL_JSON="$pull" FM_TEST_POST_LOG="$POST_LOG" \
    "$SCRIPT" https://github.com/o/r/pull/7 2>&1) || fail "a draft was not skipped: $out"
  assert_contains "$out" 'skipped: https://github.com/o/r/pull/7 is a draft' \
    "a draft pull request must be reported as skipped"
  [ "$(posted_count)" = 0 ] || fail "a draft must not receive a review request"
  pass 'a draft pull request is skipped'
}

test_refuses_non_github_and_bad_usage() {
  local status=0
  PATH="$FAKEBIN:$PATH" FM_TEST_POST_LOG="$POST_LOG" "$SCRIPT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "missing argument refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" FM_TEST_POST_LOG="$POST_LOG" "$SCRIPT" \
    https://gitlab.example.com/o/r/-/merge_requests/7 >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a non-GitHub address refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" FM_TEST_POST_LOG="$POST_LOG" "$SCRIPT" not-a-pr >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a non-URL refusal exited zero"
  pass 'usage and address refusals exit nonzero'
}

test_skips_when_no_caller_exists
test_requests_when_no_request_or_review_covers_head
test_skips_completed_review_covering_head
test_skips_existing_request_covering_head
test_skips_relay_request_covering_head
test_requests_again_after_new_head
test_skips_draft
test_refuses_non_github_and_bad_usage
