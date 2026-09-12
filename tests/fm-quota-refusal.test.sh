#!/usr/bin/env bash
# Provider quota-refusal detector and apply path.
#
# The 2026-09-11 Qwen token-plan 429 left the harness "working" with no status
# line and no cooldown. This suite pins the public detector table and the apply
# side effects (status, cooldown, one Slack line) through bin/fm-quota-refusal.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DETECT="$ROOT/bin/fm-quota-refusal.sh"
COOLDOWN="$ROOT/bin/fm-quota-cooldown.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-refusal)

QWEN_429='Error: 429: {"message":"Your token-plan 1-week quota has been exhausted. The quota will reset at 09-15 18:58:00 UTC.","type":"insufficient_quota"}'
CURSOR_LIMIT="You've hit your usage limit for Auto. Your usage limit resets 9/14/2026."
OPENAI_QUOTA='Error: 429 You exceeded your current quota, please check your plan and billing details. insufficient_quota'
XAI_QUOTA='Error: This request exceeds your xAI usage quota. Please try again later.'
ANTHROPIC_QUOTA='{"type":"error","error":{"type":"rate_limit_error","message":"You have exceeded your usage limits. Your limit will reset at 2026-09-15T00:00:00Z."}}'
ASSISTANT_TEXT_EVENT='{"type":"turn_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"The provider documentation says: You have hit your usage limit."}]}}'
PROVIDER_429_EVENT='{"type":"turn_end","message":{"role":"assistant","stopReason":"error","errorMessage":"429: Your token-plan 1-week quota has been exhausted. The quota will reset at 09-15 18:58:00 UTC."}}'
TOOL_FAILURE_EVENT='{"type":"turn_end","toolResults":[{"isError":true,"output":"429: You have hit your usage limit."}]}'
TOOL_SUCCESS_EVENT='{"type":"turn_end","toolResults":[{"isError":false,"output":"The provider documentation says: You have hit your usage limit."}]}'

detect() {
  FM_QUOTA_COOLDOWN_NOW=2026-09-12T00:00:00Z "$DETECT" detect
}

expect_detect() {
  local text=$1 provider=$2 label=$3 out status
  out=$(printf '%s\n' "$text" | detect)
  status=$?
  expect_code 0 "$status" "$label should detect"
  assert_contains "$out" "provider=$provider" "$label provider"
  printf '%s' "$out"
}

expect_undetected() {
  local text=$1 label=$2 out status
  out=$(printf '%s\n' "$text" | detect 2>&1)
  status=$?
  expect_code 1 "$status" "$label should not detect"
  assert_not_contains "$out" "provider=" "$label must not name a provider"
}

make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

test_qwen_token_plan_429_is_detected() {
  local out
  out=$(expect_detect "$QWEN_429" qwen "qwen token-plan 429")
  assert_contains "$out" "reset=2026-09-15T18:58:00Z" "qwen reset instant"
  pass "qwen token-plan 429 is detected with the provider reset instant"
}

test_each_vendor_phrasing_is_detected() {
  expect_detect "$CURSOR_LIMIT" cursor "cursor usage limit" >/dev/null
  expect_detect "$OPENAI_QUOTA" openai "openai insufficient_quota" >/dev/null
  expect_detect "$XAI_QUOTA" xai "xai usage quota" >/dev/null
  expect_detect "$ANTHROPIC_QUOTA" anthropic "anthropic rate_limit_error quota" >/dev/null
  pass "cursor, openai, xai, and anthropic quota phrasings are detected"
}

test_event_provenance_controls_phrase_matching() {
  expect_undetected "$ASSISTANT_TEXT_EVENT" "ordinary assistant text event"
  expect_detect "$PROVIDER_429_EVENT" qwen "provider 429 event" >/dev/null
  expect_undetected "$TOOL_SUCCESS_EVENT" "successful tool result"
  expect_detect "$TOOL_FAILURE_EVENT" cursor "non-zero tool result" >/dev/null
  pass "ordinary assistant text is ignored while provider and tool errors are detected"
}

test_unrelated_errors_are_not_detected() {
  expect_undetected 'Error: 500 Internal Server Error' "500"
  expect_undetected 'Error: 401 unauthorized' "401"
  expect_undetected 'context length exceeded' "context length"
  expect_undetected '429 Too Many Requests - retrying in 2s' "transient 429"
  expect_undetected 'rate limited, retrying' "retry rate limit"
  pass "unrelated errors are not treated as quota exhaustion"
}

test_apply_writes_status_records_cooldown_and_posts_slack() {
  local home fakebin out status last
  home=$(make_home apply)
  fakebin="$TMP_ROOT/apply/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-slack-post.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" > "${FM_SLACK_POST_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/fm-slack-post.sh"
  : > "$home/state/leaks-slices-brief.status"
  printf 'working: setup complete\n' > "$home/state/leaks-slices-brief.status"

  out=$(
    printf '%s\n' "$QWEN_429" | PATH="$fakebin:$PATH" FM_HOME="$home" \
      FM_QUOTA_COOLDOWN_NOW=2026-09-12T00:00:00Z FM_SLACK_POST_LOG="$home/slack.log" \
      "$DETECT" apply --task leaks-slices-brief 2>&1
  )
  status=$?
  expect_code 0 "$status" "apply should succeed"$'\n'"$out"
  last=$(tail -n 1 "$home/state/leaks-slices-brief.status")
  assert_equals "blocked [key=quota-exhausted]: qwen reset=2026-09-15T18:58:00Z" "$last" \
    "apply should append the blocked quota status line"
  FM_HOME="$home" "$COOLDOWN" list --json | jq -e \
    '.cooldowns[0] | .scope.kind=="provider" and .scope.provider=="qwen" and (.expires_at|startswith("2026-09-15T18:58:00"))' \
    >/dev/null || fail "apply did not record a provider-scope qwen cooldown"
  assert_grep "leaks-slices-brief" "$home/slack.log" "apply should post one Slack line naming the task"

  out=$(
    printf '%s\n' "$QWEN_429" | PATH="$fakebin:$PATH" FM_HOME="$home" \
      FM_QUOTA_COOLDOWN_NOW=2026-09-12T00:00:00Z FM_SLACK_POST_LOG="$home/slack.log" \
      "$DETECT" apply --task leaks-slices-brief 2>&1
  )
  status=$?
  expect_code 0 "$status" "repeat apply should be idempotent"
  [ "$(grep -c 'quota-exhausted' "$home/state/leaks-slices-brief.status")" = 1 ] \
    || fail "repeat apply appended a second blocked line"
  [ "$(wc -l < "$home/slack.log" | tr -d ' ')" = 1 ] \
    || fail "repeat apply posted Slack again"
  pass "apply writes status, records cooldown, posts Slack once"
}

test_qwen_token_plan_429_is_detected
test_each_vendor_phrasing_is_detected
test_event_provenance_controls_phrase_matching
test_unrelated_errors_are_not_detected
test_apply_writes_status_records_cooldown_and_posts_slack

echo "# all fm-quota-refusal tests passed"
