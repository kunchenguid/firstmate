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
OLD=2222222222222222222222222222222222222222
POST_LOG="$TMP_ROOT/post.log"
BODY_LOG="$TMP_ROOT/body.log"

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
  "api repos/o/r/issues/7/comments?per_page=100 --paginate --slurp")
    printf '%s\n' "${FM_TEST_COMMENTS_JSON:-[[]]}"
    ;;
  "pr comment 7 --repo o/r --body /oc review

<!-- fm-review-request head=1111111111111111111111111111111111111111 -->")
    printf '%s\n' "$*" >> "${FM_TEST_BODY_LOG:?}"
    printf 'posted\n' >> "${FM_TEST_POST_LOG:?}"
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
  : > "$BODY_LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_TEST_HEAD="$HEAD" \
    FM_TEST_POST_LOG="$POST_LOG" \
    FM_TEST_BODY_LOG="$BODY_LOG" \
    "$SCRIPT" https://github.com/o/r/pull/7
}

posted_count() {
  [ -f "$POST_LOG" ] || { printf '0\n'; return; }
  awk 'END { print NR + 0 }' "$POST_LOG"
}

marker_comment() { # <head>
  jq -n --arg body "/oc review

<!-- fm-review-request head=$1 -->" \
    '{user:{login:"saiqulhaq-hh"},body:$body}'
}

test_skips_when_no_caller_exists() {
  local out status=0
  : > "$POST_LOG"; : > "$BODY_LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_TEST_HEAD="$HEAD" FM_TEST_NO_CALLER=1 FM_TEST_POST_LOG="$POST_LOG" FM_TEST_BODY_LOG="$BODY_LOG" \
    "$SCRIPT" https://github.com/o/r/pull/7 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "an absent caller must be skipped, not refused: rc=$status $out"
  assert_contains "$out" 'skipped: no OpenCode caller workflow' \
    "an absent caller must be reported plainly"
  [ "$(posted_count)" = 0 ] || fail "no request may be posted without a caller"
  pass 'an absent caller skips the request without posting'
}

test_requests_uncovered_head_once() {
  local out
  out=$(FM_TEST_COMMENTS_JSON='[[]]' run_request) || fail "an uncovered head was not requested: $out"
  assert_contains "$out" "requested /oc review on $HEAD https://github.com/o/r/pull/7" \
    "an uncovered head must be requested"
  [ "$(posted_count)" = 1 ] || fail "exactly one request comment must be posted"
  out=$(cat "$BODY_LOG")
  assert_contains "$out" '/oc review' "the posted comment must be the review command"
  assert_contains "$out" "<!-- fm-review-request head=$HEAD -->" \
    "the posted comment must carry the head-bound marker"
  pass 'an uncovered head is requested exactly once with a head-bound marker'
}

test_skips_when_head_already_marked() {
  local out
  out=$(FM_TEST_COMMENTS_JSON="[[$(marker_comment "$HEAD")]]" run_request) \
    || fail "an already-marked head was not skipped: $out"
  assert_contains "$out" "skipped: an OpenCode review is already requested for $HEAD" \
    "the head-bound marker must suppress a duplicate"
  [ "$(posted_count)" = 0 ] || fail "a marked head must not be requested again"
  pass 'a head already marked is not requested again'
}

test_requests_after_head_moves() {
  local out
  out=$(FM_TEST_COMMENTS_JSON="[[$(marker_comment "$OLD")]]" run_request) \
    || fail "a new head after a marked review was not requested: $out"
  assert_contains "$out" "requested /oc review on $HEAD" \
    "a marker for another head must not cover the current head"
  [ "$(posted_count)" = 1 ] || fail "a moved head must produce exactly one request"
  pass 'a moved head is requested again despite an older marker'
}

test_ignores_human_and_relay_commands() {
  local out
  out=$(FM_TEST_COMMENTS_JSON="[[{\"user\":{\"login\":\"someone\"},\"body\":\"/oc review\"},{\"user\":{\"login\":\"hh-relay-dev[bot]\"},\"body\":\"<!-- relay-auto-review: x -->\"},{\"user\":{\"login\":\"opencode-agent[bot]\"},\"body\":\"findings <!-- oc-review: completed -->\"}]]" run_request) \
    || fail "a human or relay command wrongly covered the head: $out"
  assert_contains "$out" "requested /oc review on $HEAD" \
    "only this mechanism's own head marker may suppress a request"
  [ "$(posted_count)" = 1 ] || fail "a human or relay command must not suppress the request"
  pass 'human and relay commands do not count as a request or a completed review'
}

test_skips_draft() {
  local out pull
  pull=$(jq -n --arg head "$HEAD" '{head:{sha:$head},draft:true}')
  : > "$POST_LOG"; : > "$BODY_LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_TEST_HEAD="$HEAD" FM_TEST_PULL_JSON="$pull" FM_TEST_POST_LOG="$POST_LOG" FM_TEST_BODY_LOG="$BODY_LOG" \
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
test_requests_uncovered_head_once
test_skips_when_head_already_marked
test_requests_after_head_moves
test_ignores_human_and_relay_commands
test_skips_draft
test_refuses_non_github_and_bad_usage
