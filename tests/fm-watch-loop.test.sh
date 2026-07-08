#!/usr/bin/env bash
# tests/fm-watch-loop.test.sh - present-mode persistent watcher loop.
#
# The loop is the Codex-safe fallback when a one-shot background watcher exit is
# not a verified assistant wake channel. It must surface queued wakes in its own
# output and immediately re-arm, without AFK semantics and without duplicate
# loop instances.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LOOP="$ROOT/bin/fm-watch-loop.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-loop)

wait_for_pattern() {
  local file=$1 pattern=$2 limit=${3:-80} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -F "$pattern" "$file" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_loop_lock() {
  local state=$1 limit=${2:-80} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -s "$state/.watch-loop.lock/pid" ] && [ -e "$state/.watch-loop-beat" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_watch_lock_pid() {
  local state=$1 not_pid=${2:-} limit=${3:-80} i=0 pid
  while [ "$i" -lt "$limit" ]; do
    pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && [ "$pid" != "$not_pid" ] && is_live_non_zombie "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_loop() {
  local pid=${1:-}
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_loop_drains_signal_and_rearms() {
  local dir state fakebin out err status_file loop_pid first_watch second_watch
  dir=$(make_case drains-and-rearms)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/loop.out"
  err="$dir/loop.err"
  status_file="$state/task.status"

  (
    cd "$ROOT" || exit 1
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_LOOP_TICK=0.1 \
      FM_WATCH_LOOP_IDLE_SLEEP=0.1 FM_POLL=0.1 FM_SIGNAL_GRACE=0.1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bin/fm-watch-loop.sh
  ) > "$out" 2> "$err" &
  loop_pid=$!

  wait_for_loop_lock "$state" || {
    stop_loop "$loop_pid"
    fail "watch loop did not take its singleton lock"
  }
  [ "$(cat "$state/.watch-loop.lock/loop-path" 2>/dev/null || true)" = "$LOOP" ] || {
    stop_loop "$loop_pid"
    fail "watch loop did not record the absolute loop path"
  }
  first_watch=$(wait_for_watch_lock_pid "$state") || {
    stop_loop "$loop_pid"
    fail "watch loop did not start an initial watcher"
  }

  printf 'done: loop smoke surfaced\n' > "$status_file"

  wait_for_pattern "$out" "watch-loop: wake signal: $status_file" || {
    stop_loop "$loop_pid"
    fail "watch loop did not print the surfaced signal wake: $(cat "$out")"
  }
  wait_for_pattern "$out" "$(printf '\tsignal\t')" || {
    stop_loop "$loop_pid"
    fail "watch loop did not print drained wake records: $(cat "$out")"
  }
  second_watch=$(wait_for_watch_lock_pid "$state" "$first_watch") || {
    stop_loop "$loop_pid"
    fail "watch loop did not re-arm a fresh watcher after draining"
  }
  [ "$second_watch" != "$first_watch" ] || {
    stop_loop "$loop_pid"
    fail "watch loop reused the fired watcher pid instead of re-arming"
  }

  stop_loop "$loop_pid"
  pass "watch loop drains a surfaced signal and immediately re-arms"
}

test_loop_singleton_rejects_duplicate() {
  local dir state fakebin out1 out2 err1 err2 loop_pid status
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/loop-one.out"
  out2="$dir/loop-two.out"
  err1="$dir/loop-one.err"
  err2="$dir/loop-two.err"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_LOOP_TICK=0.2 \
    FM_POLL=1 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$LOOP" > "$out1" 2> "$err1" &
  loop_pid=$!
  wait_for_loop_lock "$state" || {
    stop_loop "$loop_pid"
    fail "watch loop did not take its singleton lock"
  }

  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOOP" > "$out2" 2> "$err2" || status=$?
  stop_loop "$loop_pid"

  expect_code 0 "$status" "duplicate watch-loop invocation should be a clean no-op"
  grep -F 'watch-loop: already running pid=' "$out2" >/dev/null \
    || fail "duplicate watch-loop did not report the existing loop: $(cat "$out2")"
  pass "watch loop singleton rejects duplicate instances"
}

test_loop_refuses_afk() {
  local dir state out status
  dir=$(make_case afk-refusal)
  state="$dir/state"
  out="$dir/loop.out"
  : > "$state/.afk"

  status=0
  FM_STATE_OVERRIDE="$state" "$LOOP" > "$out" || status=$?

  [ "$status" -ne 0 ] || fail "watch loop should refuse to start while AFK is active"
  grep -F 'away-mode daemon owns watcher supervision' "$out" >/dev/null \
    || fail "AFK refusal did not explain ownership: $(cat "$out")"
  pass "watch loop refuses to run while AFK daemon owns supervision"
}

test_loop_yields_when_afk_appears() {
  local dir state fakebin out err loop_pid
  dir=$(make_case afk-appears)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/loop.out"
  err="$dir/loop.err"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_LOOP_TICK=0.1 \
    FM_POLL=10 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$LOOP" > "$out" 2> "$err" &
  loop_pid=$!
  wait_for_watch_lock_pid "$state" >/dev/null || {
    stop_loop "$loop_pid"
    fail "watch loop did not start a watcher before AFK transition"
  }

  : > "$state/.afk"
  if ! wait_for_pattern "$out" "state/.afk appeared" 60; then
    stop_loop "$loop_pid"
    fail "watch loop did not report yielding after AFK appeared: $(cat "$out")"
  fi
  wait "$loop_pid" 2>/dev/null || true
  [ ! -e "$state/.watch-loop.lock" ] || fail "watch loop lock remained after AFK transition"
  pass "watch loop yields promptly when AFK appears while watcher child is idle"
}

test_loop_drains_signal_and_rearms
test_loop_singleton_rejects_duplicate
test_loop_refuses_afk
test_loop_yields_when_afk_appears
