#!/usr/bin/env bash
# tests/fm-quota-wait.test.sh - durable quota-wait registry CRUD, due-filtering,
# and bounded backoff. A parked-on-quota entry must survive as a real on-disk
# record and never busy-poll: backoff is stored, capped, and never negative.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QW="$ROOT/bin/fm-quota-wait.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-wait-tests)

new_state() {  # echo a fresh empty state dir
  local d
  mkdir -p "$TMP_ROOT"
  d=$(mktemp -d "$TMP_ROOT/state.XXXXXX")
  printf '%s\n' "$d"
}

test_record_then_get() {
  local state entry
  state=$(new_state)
  FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
    "$QW" record shipwork-1 --vendor claude --window five_hour \
    --relaunch 'fm-send shipwork-1 resume' >/dev/null
  entry=$(FM_STATE_OVERRIDE="$state" "$QW" get shipwork-1)
  assert_contains "$entry" '"vendor":"claude"' "vendor persisted"
  assert_contains "$entry" '"window":"five_hour"' "window persisted"
  assert_contains "$entry" '"relaunch":"fm-send shipwork-1 resume"' "relaunch persisted"
  assert_contains "$entry" '"attempts":0' "attempts start at zero"
  assert_present "$state/shipwork-1.quota-wait" "entry is a durable on-disk file"
  pass "record persists a durable, complete quota-wait entry"
}

test_due_filters_on_time() {
  local state due_before due_after
  state=$(new_state)
  FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
    "$QW" record late --vendor codex --wait-secs 300 >/dev/null
  due_before=$(FM_STATE_OVERRIDE="$state" "$QW" due --now 1200)
  assert_not_contains "$due_before" "late" "entry not due before its wait window"
  due_after=$(FM_STATE_OVERRIDE="$state" "$QW" due --now 1300)
  assert_contains "$due_after" "late" "entry due once the wait window passes"
  pass "due filters entries by next_check against the clock"
}

test_wait_until_is_honored() {
  local state due
  state=$(new_state)
  FM_STATE_OVERRIDE="$state" "$QW" record reset --vendor claude --wait-until 5000 >/dev/null
  due=$(FM_STATE_OVERRIDE="$state" "$QW" due --now 4999)
  assert_not_contains "$due" "reset" "not due one second before the declared reset"
  due=$(FM_STATE_OVERRIDE="$state" "$QW" due --now 5000)
  assert_contains "$due" "reset" "due at the declared reset epoch"
  pass "explicit --wait-until reset time drives due-ness"
}

test_bump_backs_off_bounded() {
  local state n1 n2 n3 attempts
  state=$(new_state)
  FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
    FM_QUOTA_WAIT_BASE_SECS=300 FM_QUOTA_WAIT_MAX_SECS=3600 \
    "$QW" record slow --vendor claude >/dev/null
  FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
    FM_QUOTA_WAIT_BASE_SECS=300 FM_QUOTA_WAIT_MAX_SECS=3600 "$QW" bump slow >/dev/null
  n1=$(FM_STATE_OVERRIDE="$state" "$QW" get slow | jq -r '.next_check')
  FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
    FM_QUOTA_WAIT_BASE_SECS=300 FM_QUOTA_WAIT_MAX_SECS=3600 "$QW" bump slow >/dev/null
  n2=$(FM_STATE_OVERRIDE="$state" "$QW" get slow | jq -r '.next_check')
  # attempt 1 -> +600, attempt 2 -> +1200 (300 * 2^attempts), both under the cap.
  [ "$n1" = "1600" ] || fail "first bump should be now+600, got $n1"
  [ "$n2" = "2200" ] || fail "second bump should be now+1200, got $n2"
  # Many bumps must clamp at the ceiling, never run away.
  for _ in 1 2 3 4 5 6 7 8; do
    FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
      FM_QUOTA_WAIT_BASE_SECS=300 FM_QUOTA_WAIT_MAX_SECS=3600 "$QW" bump slow >/dev/null
  done
  n3=$(FM_STATE_OVERRIDE="$state" "$QW" get slow | jq -r '.next_check')
  [ "$n3" = "4600" ] || fail "deep backoff should clamp at now+3600, got $n3"
  attempts=$(FM_STATE_OVERRIDE="$state" "$QW" get slow | jq -r '.attempts')
  [ "$attempts" = "10" ] || fail "attempts should count every bump, got $attempts"
  pass "bump applies bounded exponential backoff and never exceeds the cap"
}

test_clear_removes_entry() {
  local state
  state=$(new_state)
  FM_STATE_OVERRIDE="$state" "$QW" record gone --vendor claude >/dev/null
  FM_STATE_OVERRIDE="$state" "$QW" clear gone >/dev/null
  assert_absent "$state/gone.quota-wait" "clear removes the durable entry"
  pass "clear removes a resumed entry"
}

test_bad_input_rejected() {
  local state rc
  state=$(new_state)
  rc=0
  FM_STATE_OVERRIDE="$state" "$QW" record nomvendor >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "record without --vendor is a usage error"
  rc=0
  FM_STATE_OVERRIDE="$state" "$QW" record 'bad/id' --vendor claude >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a path-bearing id is rejected"
  pass "invalid record input fails closed"
}

test_record_then_get
test_due_filters_on_time
test_wait_until_is_honored
test_bump_backs_off_bounded
test_clear_removes_entry
test_bad_input_rejected
