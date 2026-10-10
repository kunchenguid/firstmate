#!/usr/bin/env bash
# Regression for a due watcher check sweep delaying the next signal scan.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
# shellcheck disable=SC2034 # make_case from wake-helpers.sh reads this global.
TMP_ROOT=$(fm_test_tmproot fm-watch-check-cadence)

test_signal_scan_runs_between_slow_checks() {
  local dir state fakebin out trace status_file pid i
  dir=$(make_case check-sweep-cadence)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  trace="$dir/check-trace"
  status_file="$state/task.status"
  : > "$trace"

  # shellcheck disable=SC2016 # The generated checks expand this path in their own shells.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "a:start\n" >> "$FM_CHECK_TRACE"' \
    '/bin/sleep 2' \
    'printf "a:end\n" >> "$FM_CHECK_TRACE"' \
    > "$state/a.check.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "b:start\n" >> "$FM_CHECK_TRACE"' \
    '/bin/sleep 2' \
    'printf "b:end\n" >> "$FM_CHECK_TRACE"' \
    > "$state/b.check.sh"
  chmod 0700 "$state/a.check.sh" "$state/b.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" a >/dev/null \
    || fail "could not register the first slow check"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" b >/dev/null \
    || fail "could not register the second slow check"

  printf 'working: baseline\n' > "$status_file"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" \
    || fail "could not prime the status baseline"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_CHECK_TRACE="$trace" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" > "$out" 2> "$dir/watch.err" &
  pid=$!
  for ((i = 0; i < 100; i++)); do
    grep -qx 'a:start' "$trace" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if ! grep -qx 'a:start' "$trace" 2>/dev/null; then
    reap "$pid"
    fail "the first slow check never started: $(cat "$dir/watch.err")"
  fi
  printf 'blocked: worker needs access\n' >> "$status_file"

  if ! wait_for_exit "$pid" 200; then
    reap "$pid"
    fail "the watcher did not surface the worker signal"
  fi
  wait "$pid" 2>/dev/null || true
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the worker signal was not surfaced: $(cat "$out")"
  if grep -qx 'b:start' "$trace"; then
    fail "the second slow check started before the signal scan"
  fi
  pass "a due watcher check sweep scans signals between slow checks"
}

test_signal_scan_runs_between_slow_checks
