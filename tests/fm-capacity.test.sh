#!/usr/bin/env bash
# Behavior tests for passive capacity classification and cooldown records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLASSIFY="$ROOT/bin/fm-capacity-classify.sh"
COOLDOWN="$ROOT/bin/fm-capacity-cooldown.sh"
FIXTURES="$ROOT/tests/fixtures/capacity-walls"
TMP_ROOT=$(fm_test_tmproot fm-capacity)

test_classifies_codex_usage_limit_with_reset() {
  local out
  out=$(FM_CAPACITY_NOW_EPOCH=1783818000 "$CLASSIFY" --file "$FIXTURES/codex-usage-limit.txt")

  assert_contains "$out" "class=quota" "codex usage wall should classify as quota"
  assert_contains "$out" "reason=codex_usage_limit" "codex usage wall should name its signature"
  assert_contains "$out" "reset_at=2:42PT" "codex usage wall should preserve observed reset text"
  assert_contains "$out" "reset_epoch=" "codex usage wall should parse a reset epoch"
  assert_contains "$out" "cooldown_ttl_secs=" "codex usage wall should expose a TTL from the reset"
  pass "codex usage-limit fixture classifies as a quota wall with reset TTL"
}

test_classifies_claude_session_limit_with_reset() {
  local out
  out=$(FM_CAPACITY_NOW_EPOCH=1783818000 "$CLASSIFY" --file "$FIXTURES/claude-session-limit.txt")

  assert_contains "$out" "class=quota" "claude session wall should classify as quota"
  assert_contains "$out" "reason=claude_session_limit" "claude session wall should name its signature"
  assert_contains "$out" "reset_at=10:50pm PT" "claude session wall should preserve observed reset text"
  assert_contains "$out" "cooldown_ttl_secs=" "claude session wall should expose a TTL from the reset"
  pass "claude session-limit fixture classifies as a quota wall with reset TTL"
}

test_classifies_proxy_auth_unavailable() {
  local out
  out=$("$CLASSIFY" --file "$FIXTURES/proxy-auth-unavailable.json")

  assert_contains "$out" "class=auth" "proxy auth_unavailable should classify as auth"
  assert_contains "$out" "reason=proxy_auth_unavailable" "proxy auth wall should name its signature"
  assert_contains "$out" "provider=codex" "proxy auth wall should extract provider"
  assert_contains "$out" "model=gpt-5.6-luna" "proxy auth wall should extract model"
  assert_not_contains "$out" "cooldown_ttl_secs=" "auth_unavailable has no observed reset TTL"
  pass "proxy auth_unavailable fixture classifies as auth without invented cooldown"
}

test_classifies_rate_limit_retry_after() {
  local out
  out=$(FM_CAPACITY_NOW_EPOCH=2000 "$CLASSIFY" --file "$FIXTURES/rate-limit-retry-after.txt")

  assert_contains "$out" "class=quota" "explicit rate limit should classify as quota"
  assert_contains "$out" "reason=rate_limit" "explicit rate limit should name its signature"
  assert_contains "$out" "reset_at=retry-after:120s" "retry-after should be preserved as reset evidence"
  assert_contains "$out" "reset_epoch=2120" "retry-after should be converted into a reset epoch"
  assert_contains "$out" "cooldown_ttl_secs=120" "retry-after should expose the TTL"
  pass "explicit rate-limit fixture classifies as quota with Retry-After TTL"
}

test_classifies_login_required() {
  local out
  out=$("$CLASSIFY" --file "$FIXTURES/login-required.txt")

  assert_contains "$out" "class=auth" "login-required should classify as auth"
  assert_contains "$out" "reason=login_required" "login-required should name its signature"
  assert_contains "$out" "provider=claude" "login-required should extract the observable provider"
  assert_not_contains "$out" "cooldown_ttl_secs=" "login-required has no observed reset TTL"
  pass "login-required fixture classifies as auth without invented cooldown"
}

test_cooldown_persists_and_expires() {
  local state out status
  state="$TMP_ROOT/cooldown/state"
  mkdir -p "$state"

  out=$(FM_STATE_OVERRIDE="$state" FM_CAPACITY_NOW_EPOCH=1000 "$COOLDOWN" mark \
    --harness codex --profile gpt-5.5/xhigh --account acct-a --reset-epoch 1600 \
    --class quota --reason codex_usage_limit --source-task task-a)
  assert_present "$out" "cooldown mark should write a record"

  out=$(FM_STATE_OVERRIDE="$state" FM_CAPACITY_NOW_EPOCH=1000 "$COOLDOWN" active \
    --harness codex --profile gpt-5.5/xhigh --account acct-a)
  assert_contains "$out" "schema=fm-capacity-cooldown.v1" "active cooldown should print the persisted record"
  assert_contains "$out" "remaining_secs=600" "active cooldown should report remaining TTL"

  set +e
  out=$(FM_STATE_OVERRIDE="$state" FM_CAPACITY_NOW_EPOCH=1600 "$COOLDOWN" active \
    --harness codex --profile gpt-5.5/xhigh --account acct-a 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "expired cooldown should return non-zero"
  [ -z "$out" ] || fail "expired cooldown should not print stale data: $out"
  pass "cooldown records persist while active and expire at reset_epoch"
}

test_mark_from_text_never_invents_auth_ttl() {
  local state out status
  state="$TMP_ROOT/no-auth-ttl/state"
  mkdir -p "$state"

  set +e
  out=$(FM_STATE_OVERRIDE="$state" "$COOLDOWN" mark-from-text \
    --harness pi --profile gpt-5.6-luna --file "$FIXTURES/proxy-auth-unavailable.json" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "auth_unavailable without reset should not write cooldown"
  assert_contains "$out" "class=auth" "mark-from-text should still print classification"
  assert_contains "$out" "no observed reset epoch" "mark-from-text should explain refusal"
  assert_absent "$state/capacity-cooldowns" "auth_unavailable without reset must not create cooldown dir"
  pass "mark-from-text refuses to invent TTLs for auth_unavailable"
}

test_classifies_codex_usage_limit_with_reset
test_classifies_claude_session_limit_with_reset
test_classifies_proxy_auth_unavailable
test_classifies_rate_limit_retry_after
test_classifies_login_required
test_cooldown_persists_and_expires
test_mark_from_text_never_invents_auth_ttl

echo "# all fm-capacity tests passed"
