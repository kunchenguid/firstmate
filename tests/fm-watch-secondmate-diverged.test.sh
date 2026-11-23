#!/usr/bin/env bash
# Aged secondmate divergence records re-surface through the watcher's real queue.
# No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-secondmate-diverged)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

DAY=86400
REC="$STATE/.secondmate-update-reconcile"

reset_case() {
  rm -rf -- "${STATE:?}"/* "$STATE"/.[!.]*
  mkdir -p "$REC"
  SECONDMATE_DIVERGED_REMINDER=
}

write_record() {  # <id> [first-seen]
  {
    printf 'schema=fm-secondmate-update-reconcile.v1\nid=%s\nstatus=diverged\n' "$1"
    printf 'local_commit=1111111111111111aaaa\ntarget_commit=2222222222222222bbbb\ntarget=main\n'
    [ -z "${2:-}" ] || printf 'first_seen=%s\n' "$2"
  } > "$REC/$1.pending"
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

ack_wakes() { rm -f -- "$FM_WAKE_QUEUE"; }

test_threshold_and_repeat() {
  reset_case
  write_record sm1 1000000
  secondmate_diverged_reminder_tick "$((1000000 + DAY - 1))"
  [ "$(count_wakes)" = 0 ] || fail "a record younger than a day queued a reminder"
  secondmate_diverged_reminder_tick "$((1000000 + DAY + 3600))"
  [ "$(count_wakes)" = 1 ] || fail "a day-old record did not queue exactly one reminder"
  [ "$SECONDMATE_DIVERGED_REMINDER" = "check: secondmate sm1 still diverged after 1d1h: local 111111111111 target 222222222222 (record: $REC/sm1.pending)" ] \
    || fail "reminder lacks the home, both commits, or the age: $SECONDMATE_DIVERGED_REMINDER"
  ack_wakes
  secondmate_diverged_reminder_tick "$((1000000 + 4 * DAY + 3599))"
  [ "$(count_wakes)" = 0 ] || fail "reminder repeated before its interval"
  [ -z "$SECONDMATE_DIVERGED_REMINDER" ] || fail "a quiet tick still reported a reminder"
  secondmate_diverged_reminder_tick "$((1000000 + 4 * DAY + 3600))"
  [ "$(count_wakes)" = 1 ] || fail "reminder did not repeat after its interval"
  pass "a stuck home is reported after a day and again every three days"
}

test_unacknowledged_reminder_is_not_duplicated() {
  reset_case
  write_record sm1 1000000
  secondmate_diverged_reminder_tick "$((1000000 + DAY))"
  rm -f -- "$STATE/.secondmate-diverged-reminders"
  secondmate_diverged_reminder_tick "$((1000000 + DAY + 60))"
  [ "$(count_wakes)" = 1 ] || fail "a still-queued reminder was queued again"
  pass "a reminder still waiting in the queue is not duplicated"
}

test_cleared_record_resets() {
  reset_case
  write_record sm1 1000000
  secondmate_diverged_reminder_tick "$((1000000 + DAY))"
  ack_wakes
  rm -f -- "$REC/sm1.pending"
  secondmate_diverged_reminder_tick "$((1000000 + DAY + 60))"
  [ "$(count_wakes)" = 0 ] || fail "a cleared record still produced a reminder"
  [ ! -e "$STATE/.secondmate-diverged-reminders" ] || fail "a cleared record left reminder bookkeeping"
  write_record sm1 2000000
  secondmate_diverged_reminder_tick "$((2000000 + DAY))"
  [ "$(count_wakes)" = 1 ] || fail "a new divergence episode inherited the old reminder time"
  pass "a converged home goes quiet and a later divergence starts fresh"
}

test_legacy_record_uses_file_time() {
  local now
  reset_case
  write_record sm-old
  fm_epoch_seconds_to now
  fm_touch_epoch "$((now - 2 * DAY))" "$REC/sm-old.pending"
  secondmate_diverged_reminder_tick "$now"
  [ "$(count_wakes)" = 1 ] || fail "a record without first_seen was never reported"
  assert_contains "$SECONDMATE_DIVERGED_REMINDER" "secondmate sm-old still diverged after 2d0h" \
    "a record without first_seen did not age from its file time"
  pass "a record written before first_seen ages from its file time"
}

test_invalid_settings_fail() {
  reset_case
  write_record sm1 1000000
  if FM_SECONDMATE_DIVERGED_REMIND_SECS=0 secondmate_diverged_reminder_tick 2000000 2>/dev/null; then
    fail "a zero threshold was accepted"
  fi
  [ "$(count_wakes)" = 0 ] || fail "an invalid setting still queued a reminder"
  pass "invalid reminder settings fail instead of looping"
}

test_threshold_and_repeat
test_unacknowledged_reminder_is_not_duplicated
test_cleared_record_resets
test_legacy_record_uses_file_time
test_invalid_settings_fail
