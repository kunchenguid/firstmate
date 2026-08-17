#!/usr/bin/env bash
# Behavior tests for the public status-report producer boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-status-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-report)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

report_event() {
  "$REPORT" "$1" "$2"
}

line_count() {
  awk 'END { print NR + 0 }' "$1"
}

# Each call is a fresh producer process through the public reporting command.
# Before the reporter exists, the second call cannot suppress the duplicate.
test_unchanged_keyed_pause_is_suppressed() {
  local home status line out
  home=$(make_home duplicate)
  status="$home/state/held.status"
  line='paused [key=upstream-release]: waiting for upstream release'

  out=$(report_event "$status" "$line") || fail "initial keyed pause report failed"
  [ "$out" = appended ] || fail "initial keyed pause was not appended: $out"
  out=$(report_event "$status" "$line") || fail "duplicate keyed pause report failed"
  [ "$out" = suppressed ] || fail "unchanged keyed pause was not suppressed: $out"
  [ "$(line_count "$status")" -eq 1 ] || fail "unchanged keyed pause grew status history"
  pass "unchanged keyed pauses are suppressed at the public producer boundary"
}

test_changed_state_and_unkeyed_events_are_delivered() {
  local home status first changed resolved unkeyed out
  home=$(make_home transitions)
  status="$home/state/held.status"
  first='paused [key=upstream-release]: waiting for upstream release'
  changed='paused [key=upstream-release]: waiting for vendor approval'
  resolved='resolved [key=upstream-release]: upstream release landed'
  unkeyed='paused: waiting for an unkeyed external dependency'

  report_event "$status" "$first" >/dev/null || fail "initial keyed pause failed"
  out=$(report_event "$status" "$changed") || fail "changed keyed pause failed"
  [ "$out" = appended ] || fail "changed keyed pause was suppressed: $out"
  out=$(report_event "$status" "$resolved") || fail "keyed state transition failed"
  [ "$out" = appended ] || fail "keyed state transition was suppressed: $out"
  out=$(report_event "$status" "$first") || fail "keyed pause after transition failed"
  [ "$out" = appended ] || fail "keyed pause after transition was suppressed: $out"
  report_event "$status" "$unkeyed" >/dev/null || fail "first unkeyed pause failed"
  report_event "$status" "$unkeyed" >/dev/null || fail "second unkeyed pause failed"
  [ "$(line_count "$status")" -eq 6 ] || fail "a meaningful or unkeyed status event was lost"
  pass "changed keyed state and unkeyed status events remain observable"
}

test_unchanged_keyed_pause_is_suppressed
test_changed_state_and_unkeyed_events_are_delivered
