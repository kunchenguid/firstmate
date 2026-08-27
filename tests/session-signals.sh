#!/usr/bin/env bash
# tests/session-signals.sh - the one owner of the session-cohort signal list.
#
# Every environment variable the session-lock cohort proof reads: the launch
# markers in FM_SESSION_LAUNCH_MARKERS, and the container guards and pane ids in
# FM_SESSION_CONTAINERS (bin/fm-session-lock-lib.sh owns both tables). Both are
# row-per-line tables whose first column is the harness or provider that owns the
# row, so both are read the same way and only the variable columns are emitted.
#
# A fixture that starts a harness-named process MUST clear all of them, or that
# process inherits the captain session's own launch marker and pane id, is
# genuinely in the cohort of the process asking about it, and a control that
# reads as "a separate concurrent session" silently becomes "this session's own
# holder".
#
# The list is DERIVED from those tables rather than transcribed, so a verified row
# added to FM_SESSION_CONTAINERS - zellij and orca are named there as pending -
# or a second launch marker is cleared by every suite at once. Three consumers
# read it: tests/lib.sh for the portable suites, and the two opt-in live guards
# directly, because they must not source tests/lib.sh (it arms EXIT traps,
# exports FM_GATE_REFUSE_BYPASS, and reaps orphan fixture roots on source).
#
# This file is sourced and has no side effects beyond the two names below. The
# derivation runs in a subshell, so the library's own functions and tables do not
# leak into a suite that never asked for them.

FM_TEST_SESSION_SIGNAL_VARS=$(
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fm-session-lock-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$lib" || exit 1
  while read -r _ var; do
    [ -n "$var" ] || continue
    printf '%s\n' "$var"
  done <<MARKERS
$FM_SESSION_LAUNCH_MARKERS
MARKERS
  while read -r _ guard panevar; do
    [ -n "$guard" ] || continue
    printf '%s\n%s\n' "$guard" "$panevar"
  done <<TABLE
$FM_SESSION_CONTAINERS
TABLE
) || FM_TEST_SESSION_SIGNAL_VARS=
FM_TEST_SESSION_SIGNAL_VARS=$(printf '%s' "$FM_TEST_SESSION_SIGNAL_VARS" | tr '\n' ' ')

case "$FM_TEST_SESSION_SIGNAL_VARS" in
  *CLAUDE_PID*) : ;;
  *)
    printf 'session-signals: cannot derive the cohort signal list from bin/fm-session-lock-lib.sh\n' >&2
    exit 1
    ;;
esac

# Populate FM_TEST_CLEAR_SIGNALS_ARGV with an `env -u ...` prefix that clears
# every one of them. Bash 3.2 has no namerefs, so the array is the return value.
FM_TEST_CLEAR_SIGNALS_ARGV=()
fm_test_clear_signals_argv() {
  local var
  FM_TEST_CLEAR_SIGNALS_ARGV=(env)
  for var in $FM_TEST_SESSION_SIGNAL_VARS; do
    FM_TEST_CLEAR_SIGNALS_ARGV+=(-u "$var")
  done
}
