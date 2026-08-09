#!/usr/bin/env bash
# Behavior of the shared bounded wait in tests/lib.sh.
#
# Every suite that blocks a real worker at a fixture barrier polls for its
# marker, and the bound those polls carry is what decides whether a slow runner
# reports a hang. This pins the wait's contract: wall-clock bound, a distinct
# verdict for a dead producer, and no false "exited" when the producer writes
# its marker and exits in the same breath.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-lib-wait)
mkdir -p "$TMP_ROOT"

# Run one fm_test_wait_file call in its own shell so its fail() aborts only that
# shell. Echoes the call's exit status; its output is captured by the caller.
run_wait() { # <marker> <seconds> <pid|-> <out-file>
  bash -c '
    . "$1"
    fm_test_wait_file "$2" "$3" "$4" "producer exited" "wait timed out"
    printf "returned\n"
  ' _ "$LIB" "$1" "$2" "$3" > "$4" 2>&1
}

test_returns_as_soon_as_the_marker_appears() {
  local marker="$TMP_ROOT/appears.marker" out="$TMP_ROOT/appears.out" producer status
  ( sleep 0.3; : > "$marker" ) &
  producer=$!
  fm_test_reap "$producer"
  run_wait "$marker" 30 "$producer" "$out"
  status=$?
  wait "$producer" 2>/dev/null || true
  expect_code 0 "$status" "wait aborted while its producer was still working"
  assert_grep returned "$out" "wait did not return after the marker appeared"
  pass "the wait returns once its marker appears"
}

# Time out one wait whose marker never appears; echo the seconds it spent.
time_out_wait() { # <label> <seconds>
  local label=$1 seconds=$2 marker="$TMP_ROOT/never-$1.marker" out="$TMP_ROOT/never-$1.out"
  local producer status started elapsed
  ( sleep 60 ) &
  producer=$!
  fm_test_reap "$producer"
  started=$SECONDS
  run_wait "$marker" "$seconds" "$producer" "$out"
  status=$?
  elapsed=$((SECONDS - started))
  kill "$producer" 2>/dev/null || true
  expect_code 1 "$status" "a wait whose marker never appears must fail ($label)"
  assert_grep "wait timed out" "$out" "timeout did not report its own message ($label)"
  printf '%s\n' "$elapsed"
}

test_bound_is_wall_clock_seconds_not_iterations() {
  local short_elapsed long_elapsed
  short_elapsed=$(time_out_wait short 1) || exit 1
  long_elapsed=$(time_out_wait long 5) || exit 1
  # Two independent failure modes, and a poll count catches neither. A count
  # spends whatever its polls happen to cost on the day - too little on a loaded
  # runner, which is what reports a slow worker as a hang - and it spends the
  # same amount whatever bound the caller asked for.
  [ "$short_elapsed" -ge 1 ] || fail "wait gave up after ${short_elapsed}s of a 1s bound"
  [ "$long_elapsed" -ge 5 ] || fail "wait gave up after ${long_elapsed}s of a 5s bound"
  [ "$((long_elapsed - short_elapsed))" -ge 2 ] \
    || fail "a 5s bound outlasted a 1s bound by only $((long_elapsed - short_elapsed))s, so the bound is not the seconds asked for"
  pass "the bound is wall-clock seconds, spent in full and scaled to the caller's request"
}

test_dead_producer_is_reported_apart_from_a_timeout() {
  local marker="$TMP_ROOT/dead.marker" out="$TMP_ROOT/dead.out" producer status started elapsed
  ( sleep 0.2; exit 3 ) &
  producer=$!
  fm_test_reap "$producer"
  started=$SECONDS
  run_wait "$marker" 60 "$producer" "$out"
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "a wait whose producer died must fail"
  assert_grep "producer exited" "$out" "dead producer was not reported as an exit"
  assert_no_grep "wait timed out" "$out" "dead producer was reported as a timeout"
  [ "$elapsed" -le 30 ] || fail "dead producer was not noticed until the bound expired"
  pass "a producer that dies without its marker is reported apart from a timeout"
}

test_returns_as_soon_as_the_marker_appears
test_bound_is_wall_clock_seconds_not_iterations
test_dead_producer_is_reported_apart_from_a_timeout

echo "ALL TESTS PASSED"
