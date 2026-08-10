#!/usr/bin/env bash
# Regression tests for the private business-agenda scheduler.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCAN="$ROOT/bin/fm-agenda-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-agenda-scan)
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}
write_registry() {
  local home=$1
  shift
  printf '%s\n' \
    '# Business agenda registry.' \
    '# Format: - <id> | <cadence> | <owner> | <action> | <delivery>' \
    "$@" > "$home/data/business-agenda.md"
}
run_scan() {
  local home=$1 date_value=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AGENDA_DATE="$date_value" "$SCAN"
}
test_daily_fires_once_per_local_day() {
  local home out
  home=$(make_home daily)
  write_registry "$home" \
    '- daily-item | daily | seller-outreach | draft the daily follow-up | notify'
  out=$(run_scan "$home" 2026-08-10)
  [ "$out" = 'agenda-due: daily-item | seller-outreach | draft the daily follow-up' ] \
    || fail "daily item did not fire on its first day"
  out=$(run_scan "$home" 2026-08-10)
  [ -z "$out" ] || fail "daily item fired twice on the same day"
  [ "$(cat "$home/state/.agenda-fired")" = 'daily-item|daily|2026-08-10' ] \
    || fail "daily fire state did not record the current period"
  out=$(run_scan "$home" 2026-08-11)
  [ "$out" = 'agenda-due: daily-item | seller-outreach | draft the daily follow-up' ] \
    || fail "daily item did not fire on the next day"
  pass "daily items fire once per local day"
}
test_weekly_fires_only_on_matching_weekday() {
  local home out
  home=$(make_home weekly)
  write_registry "$home" \
    '- monday-item | weekly:mon | business-processes | draft the weekly update | notify'
  out=$(run_scan "$home" 2026-08-10)
  [ "$out" = 'agenda-due: monday-item | business-processes | draft the weekly update' ] \
    || fail "weekly Monday item did not fire on Monday"
  out=$(run_scan "$home" 2026-08-10)
  [ -z "$out" ] || fail "weekly Monday item fired twice on Monday"
  out=$(run_scan "$home" 2026-08-11)
  [ -z "$out" ] || fail "weekly Monday item fired on Tuesday"
  out=$(run_scan "$home" 2026-08-17)
  [ "$out" = 'agenda-due: monday-item | business-processes | draft the weekly update' ] \
    || fail "weekly Monday item did not fire on the next Monday"
  pass "weekly items fire only on their matching weekday"
}
test_nothing_due_is_silent_and_does_not_create_fire_state() {
  local home out
  home=$(make_home silent)
  write_registry "$home" \
    '- monday-item | weekly:mon | monitoring | check the monitor | notify-on-problem'
  out=$(run_scan "$home" 2026-08-11)
  [ -z "$out" ] || fail "non-matching weekly item printed output"
  [ ! -e "$home/state/.agenda-fired" ] \
    || fail "a silent scan changed fire state"
  pass "nothing due prints nothing and leaves fire state unchanged"
}
test_fire_state_prevents_repeats_after_scan_restart() {
  local home first second
  home=$(make_home restart)
  write_registry "$home" \
    '- daily-item | daily | monitoring | check the monitor | notify'
  first=$(run_scan "$home" 2026-08-10)
  second=$(run_scan "$home" 2026-08-10)
  [ -n "$first" ] && [ -z "$second" ] \
    || fail "durable fire state did not prevent a repeat after restart"
  pass "durable fire state prevents repeats"
}
test_daily_fires_once_per_local_day
test_weekly_fires_only_on_matching_weekday
test_nothing_due_is_silent_and_does_not_create_fire_state
test_fire_state_prevents_repeats_after_scan_restart
