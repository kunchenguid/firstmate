#!/usr/bin/env bash
# Shared bounded condition waits; bin/fm-test-run.sh owns FM_TEST_TIMEOUT_SCALE.
# Safe to source from the runner and from fixture subprocesses without cleanup traps.
case "${FM_TEST_TIMEOUT_SCALE:=1}" in
  [1-9]|[1-9][0-9]|100) ;;
  *) printf 'error: FM_TEST_TIMEOUT_SCALE must be an integer from 1 to 100\n' >&2; exit 2 ;;
esac
export FM_TEST_TIMEOUT_SCALE

fm_test_timeout() { # <base-seconds-or-ticks>
  printf '%s\n' "$(( $1 * FM_TEST_TIMEOUT_SCALE ))"
}

fm_test_wait_until() { # <base-ticks> <condition-command> [args...]; 0.1s sampling
  local remaining=$(( $1 * FM_TEST_TIMEOUT_SCALE ))
  shift
  while ! "$@"; do
    [ "$remaining" -gt 0 ] || return 1
    remaining=$((remaining - 1))
    sleep 0.1
  done
}
