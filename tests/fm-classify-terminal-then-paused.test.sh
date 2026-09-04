#!/usr/bin/env bash
# tests/fm-classify-terminal-then-paused.test.sh - unit coverage for
# status_terminal_then_paused (bin/fm-classify-lib.sh), the shared predicate a
# worker's "done: ... then paused: <why>" finished-into-a-wait shape must be
# recognized through. Exercises the pure function directly with crafted line
# lists rather than through the full watcher, complementing the end-to-end
# coverage in tests/fm-watch-triage.test.sh (which drives the real watcher
# process over bin/fm-watch.sh's terminal_then_paused wrapper).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

test_done_then_paused_is_terminal() {
  local lines last
  lines=$'working: finishing now\ndone: PR https://example.test/owner/repo/pull/1 checks green\npaused: awaiting merge authority'
  last='paused: awaiting merge authority'
  status_terminal_then_paused "$lines" "$last" \
    || fail "a done: line followed by a single paused: line was not recognized as terminal"
  pass "a done-then-paused sequence is recognized as terminal"
}

test_done_then_multiple_pauses_is_terminal() {
  local lines last
  lines=$'done: PR https://example.test/owner/repo/pull/1 checks green\npaused: awaiting merge authority\npaused: still awaiting merge authority'
  last='paused: still awaiting merge authority'
  status_terminal_then_paused "$lines" "$last" \
    || fail "a done: line followed by two paused: lines was not recognized as terminal"
  pass "a done-then-multiple-pauses sequence is recognized as terminal"
}

test_bare_paused_with_no_preceding_terminal_line_is_not_terminal() {
  local lines last
  lines=$'working: making progress\npaused: awaiting an upstream release'
  last='paused: awaiting an upstream release'
  ! status_terminal_then_paused "$lines" "$last" \
    || fail "a standalone declared pause with no preceding done/failed line was reported as terminal"
  pass "a standalone declared pause with no preceding terminal line is not terminal"
}

test_last_line_not_paused_is_not_terminal() {
  local lines last
  lines=$'done: PR https://example.test/owner/repo/pull/1 checks green\nworking: resumed after a steer'
  last='working: resumed after a steer'
  ! status_terminal_then_paused "$lines" "$last" \
    || fail "a log whose last line is not a declared pause was reported as terminal"
  pass "a log whose last line is not a declared pause is not terminal"
}

# FM_TERMINAL_PAUSE_SCAN_MAX is an operator override, so a non-numeric or
# non-positive value must fall back to FM_TERMINAL_PAUSE_SCAN_MAX_DEFAULT
# rather than making `[` error to stderr and silently disabling recognition.
test_invalid_scan_budget_falls_back_to_default() {
  local lines last bad err
  lines=$'done: PR https://example.test/owner/repo/pull/1 checks green\npaused: awaiting merge authority'
  last='paused: awaiting merge authority'
  for bad in twenty 0; do
    err=$(FM_TERMINAL_PAUSE_SCAN_MAX="$bad" status_terminal_then_paused "$lines" "$last" 2>&1 >/dev/null)
    [ -z "$err" ] \
      || fail "FM_TERMINAL_PAUSE_SCAN_MAX=$bad made the scan write to stderr: $err"
    FM_TERMINAL_PAUSE_SCAN_MAX="$bad" status_terminal_then_paused "$lines" "$last" \
      || fail "FM_TERMINAL_PAUSE_SCAN_MAX=$bad disabled recognition instead of falling back to the default"
  done
  pass "a non-numeric or zero scan budget falls back to the default instead of disabling recognition"
}

test_scan_budget_bounds_the_lookback() {
  local lines last
  # 30 declared pauses stacked on top of a done: line: with the default budget
  # of 20, the scan exhausts its lookback before ever reaching the done: line
  # at the head, so this must NOT be reported as terminal.
  lines="done: PR https://example.test/owner/repo/pull/1 checks green"
  local i
  for i in $(seq 1 30); do
    lines="$lines"$'\n'"paused: recheck $i"
  done
  last="paused: recheck 30"
  ! status_terminal_then_paused "$lines" "$last" \
    || fail "the scan reached beyond its budget and found a done: line it should not have"
  pass "the bounded lookback does not scan past its budget"
}

test_done_then_paused_is_terminal
test_done_then_multiple_pauses_is_terminal
test_bare_paused_with_no_preceding_terminal_line_is_not_terminal
test_last_line_not_paused_is_not_terminal
test_invalid_scan_budget_falls_back_to_default
test_scan_budget_bounds_the_lookback
