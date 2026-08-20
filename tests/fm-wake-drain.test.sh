#!/usr/bin/env bash
# Characterization tests for the durable wake queue drain entry point.
set -u

# shellcheck source=tests/wake-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
# shellcheck disable=SC2034 # consumed by make_case from wake-helpers.sh
TMP_ROOT=$(fm_test_tmproot fm-wake-drain)

test_drain_consumes_and_deduplicates_wakes() {
  local dir state out count
  dir=$(make_case basic)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" signal task.status "signal: first" || fail "first wake append failed"
  append_wake "$state" signal task.status "signal: second" || fail "second wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "wake drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 1 ] || fail "duplicate wake was not collapsed: $(cat "$out")"
  grep -F "signal: second" "$out" >/dev/null || fail "latest duplicate payload was not retained"
  [ ! -s "$state/.wake-queue" ] || fail "wake queue was not emptied after a successful drain"
  pass "drain consumes queued wakes and keeps the latest duplicate payload"
}

test_empty_drain_is_silent() {
  local dir state out
  dir=$(make_case empty)
  state="$dir/state"
  out="$dir/drain.out"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty wake drain failed"
  [ ! -s "$out" ] || fail "empty wake drain emitted unexpected output: $(cat "$out")"
  [ -f "$state/.wake-queue" ] || fail "empty drain did not materialize the wake queue"
  pass "empty drain succeeds silently"
}

test_drain_consumes_and_deduplicates_wakes
test_empty_drain_is_silent
