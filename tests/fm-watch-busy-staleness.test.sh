#!/usr/bin/env bash
# Behavior tests for the native-busy staleness guard
# (fm_busy_native_stale / fm_busy_native_clear, consulted by the herdr-native
# arm of fm_busy_classify in bin/fm-busy-lib.sh).
#
# Herdr reports agent_status per pane, but only for the harnesses it
# integrates with. It has NO cline integration, so its agent_status for a cline
# pane is a guess that sticks at "working" forever; trusting it unbounded would
# leave supervision waiting on an already-finished task indefinitely. Past
# FM_BUSY_NATIVE_MAX_SECONDS (default 120) of continuous native busy for the
# same task, the classifier stops trusting the native signal and reports
# "unknown native-stale". For claude/codex/pi/copilot, whose native signals are
# correct, trust is unbounded and the hot path is unchanged.
#
# These tests call the real classifier directly with only fm_backend_busy_state
# stubbed, so they exercise the shipped guard rather than a copy of it.
#
# NOTE ON SCOPE: this suite previously sed-extracted window_is_busy() from
# bin/fm-watch.sh. That function now delegates entirely to this shared
# classifier, so the extraction tested nothing (it failed on undefined
# symbols). The guard's contract lives here now, and so does its cover.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

# classify <native-state> <harness> <state-dir> -> "<verdict> <source>"
# Runs the real fm_busy_classify in a subshell with the backend's native busy
# probe stubbed, against a task id of t1 and no recorded busy event (so the
# herdr-native arm is the one under test).
# The stub's value is held in a deliberately unique name: bash's dynamic scoping
# means a stub reading a common name like $native would resolve to
# fm_busy_classify's own `local native` (empty at call time), not to ours.
classify() {
  local _fm_stub_native=$1 harness=$2 state=$3
  (
    # Both of these are consumed by the sourced classifier, not by this file:
    # fm_busy_classify reaches the stub through `command -v`, and
    # fm_busy_native_stale reads the threshold. ShellCheck sees neither use.
    # shellcheck disable=SC2329  # invoked indirectly by fm_busy_classify
    fm_backend_busy_state() { printf '%s' "$_fm_stub_native"; }
    # shellcheck disable=SC2034  # read by fm_busy_native_stale in fm-busy-lib.sh
    FM_BUSY_NATIVE_MAX_SECONDS=120
    fm_busy_classify herdr win:0 "$harness" t1 "$state" "idle pane tail"
  )
}

# age_marker <state-dir> <seconds-ago> - backdate the continuous-busy marker.
age_marker() {
  local state=$1 ago=$2 now
  now=${EPOCHSECONDS:-$(date +%s)}
  echo $((now - ago)) > "$state/.busy-since-t1"
}

test_under_threshold_trusts_native_for_integrated_harness() {
  # Unchanged hot path: claude's native busy is correct, so it is trusted.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-under-threshold); mkdir -p "$tmpd"
  out=$(classify busy claude "$tmpd")
  [ "$out" = "busy herdr-native" ] \
    || fail "under-threshold native busy must return busy (unchanged hot path), got '$out'"
  pass "fm_busy_classify: under-threshold native busy trusts the native signal"
}

test_under_threshold_trusts_native_for_cline() {
  # The guard must not fire early: a cline task inside the trust window is busy.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-cline-fresh); mkdir -p "$tmpd"
  age_marker "$tmpd" 5
  out=$(classify busy cline "$tmpd")
  [ "$out" = "busy herdr-native" ] \
    || fail "cline native busy inside the trust window must return busy, got '$out'"
  pass "fm_busy_classify: cline native busy inside the trust window is still busy"
}

test_first_native_busy_arms_the_window_without_reporting_stale() {
  # With no marker yet, the first native busy must arm the window and report
  # busy - never stale on first sight.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-first-sight); mkdir -p "$tmpd"
  [ -e "$tmpd/.busy-since-t1" ] && fail "precondition: marker must not exist yet"
  out=$(classify busy cline "$tmpd")
  [ "$out" = "busy herdr-native" ] \
    || fail "first native busy must report busy, got '$out'"
  [ -f "$tmpd/.busy-since-t1" ] \
    || fail "first native busy must arm the continuous-busy marker"
  pass "fm_busy_classify: first native busy arms the staleness window and reports busy"
}

test_stale_native_busy_stops_being_trusted_for_cline() {
  # The guard itself: past the threshold a never-flipping cline native busy
  # must stop being trusted, so supervision can reap the finished task.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-stale); mkdir -p "$tmpd"
  age_marker "$tmpd" 200
  out=$(classify busy cline "$tmpd")
  [ "$out" = "unknown native-stale" ] \
    || fail "stale cline native busy must report 'unknown native-stale', got '$out'"
  pass "fm_busy_classify: stale cline native busy is no longer trusted as busy"
}

test_stale_trust_is_bounded_only_for_unintegrated_harnesses() {
  # A legitimately long claude turn must keep reading busy no matter how long
  # it runs - the time bound applies to cline only.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-stale-claude); mkdir -p "$tmpd"
  age_marker "$tmpd" 100000
  out=$(classify busy claude "$tmpd")
  [ "$out" = "busy herdr-native" ] \
    || fail "an integrated harness must never be time-bounded, got '$out'"
  pass "fm_busy_classify: the staleness bound applies to cline only, never to claude"
}

test_idle_resets_the_staleness_window() {
  # Native idle clears the per-task marker so a later busy starts a fresh
  # window with no stale carryover.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-idle-reset); mkdir -p "$tmpd"
  age_marker "$tmpd" 200
  out=$(classify idle cline "$tmpd")
  [ "${out%% *}" != busy ] \
    || fail "native idle must not classify as busy, got '$out'"
  if [ -e "$tmpd/.busy-since-t1" ]; then
    fail "native idle must clear the continuous-busy marker"
  fi
  pass "fm_busy_classify: native idle clears the per-task staleness marker"
}

test_unknown_native_state_clears_the_window() {
  # A non-busy/non-idle native value must also clear the marker so it cannot
  # masquerade as stale later.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-unknown); mkdir -p "$tmpd"
  age_marker "$tmpd" 200
  out=$(classify unknown cline "$tmpd")
  [ "${out%% *}" != busy ] \
    || fail "unknown native state must not classify as busy, got '$out'"
  if [ -e "$tmpd/.busy-since-t1" ]; then
    fail "unknown native state must clear the continuous-busy marker"
  fi
  pass "fm_busy_classify: unknown native state clears the per-task staleness marker"
}

test_boolean_view_rejects_a_stale_native_busy() {
  # End-to-end guarantee the guard exists for: the boolean view that
  # supervision gates on must report not-busy once trust has expired.
  local tmpd
  tmpd=$(fm_test_tmproot busy-bool); mkdir -p "$tmpd"
  age_marker "$tmpd" 200
  if (
    # shellcheck disable=SC2329  # invoked indirectly by fm_busy_classify
    fm_backend_busy_state() { printf busy; }
    # shellcheck disable=SC2034  # read by fm_busy_native_stale in fm-busy-lib.sh
    FM_BUSY_NATIVE_MAX_SECONDS=120
    fm_busy_is_busy herdr win:0 cline t1 "$tmpd" "idle pane tail"
  ); then
    fail "fm_busy_is_busy must be false once native trust has expired"
  fi
  pass "fm_busy_is_busy: a stale cline native busy no longer blocks supervision"
}

# --- run --------------------------------------------------------------------
test_under_threshold_trusts_native_for_integrated_harness
test_under_threshold_trusts_native_for_cline
test_first_native_busy_arms_the_window_without_reporting_stale
test_stale_native_busy_stops_being_trusted_for_cline
test_stale_trust_is_bounded_only_for_unintegrated_harnesses
test_idle_resets_the_staleness_window
test_unknown_native_state_clears_the_window
test_boolean_view_rejects_a_stale_native_busy
echo "ALL PASS: fm-watch-busy-staleness"
