#!/usr/bin/env bash
# tests/fm-watch-signal-grace.test.sh - FM_SIGNAL_GRACE is a maximum, not a fixed
# wait: bin/fm-watch.sh ends the grace early once every terminal or paused status
# in the batch already has a newer <id>.turn-ended marker, and otherwise waits the
# whole grace as before.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-signal-grace-tests)

# run_batch <name> <grace> <status-file-spec>...
# A spec is "<task>:<status line>" or "<task>:<status line>:marker". The marker is
# written after a pause so it is strictly newer than its status file. Prints the
# whole seconds the watcher took to exit with its wake. When LATE_STATUS is set
# to "<task>:<status line>", that status is written, with no marker, by the first
# one-second sleep the watcher runs, which is its first grace poll since the main
# loop sleeps FM_POLL=2.
run_batch() {
  local name=$1 grace=$2 dir state fakebin out pid spec task line start poll
  shift 2
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  for spec in "$@"; do
    task=${spec%%:*}; line=${spec#*:}; line=${line%:marker}
    printf '%s\n' "$line" > "$state/$task.status"
  done
  sleep 1.1
  for spec in "$@"; do
    case "$spec" in *:marker) : > "$state/${spec%%:*}.turn-ended" ;; esac
  done
  poll=1
  if [ -n "${LATE_STATUS:-}" ]; then
    poll=2
    cat > "$fakebin/sleep" <<SLEEP
#!/usr/bin/env bash
if [ "\$1" = 1 ] && [ ! -e "$dir/late-written" ]; then
  printf '%s\n' '${LATE_STATUS#*:}' > "$state/${LATE_STATUS%%:*}.status"
  : > "$dir/late-written"
fi
exec $(command -v sleep) "\$@"
SLEEP
    chmod +x "$fakebin/sleep"
  fi
  start=$SECONDS
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=$poll FM_SIGNAL_GRACE="$grace" FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 450 || fail "$name: watcher did not exit: $(cat "$out")"
  grep -F "signal:" "$out" >/dev/null || fail "$name: no signal wake: $(cat "$out")"
  printf '%s\n' "$((SECONDS - start))"
}

test_terminal_status_with_newer_marker_ends_grace_early() {
  local elapsed
  elapsed=$(run_batch early 30 't1:done: finished:marker')
  [ "$elapsed" -le 24 ] || fail "settled batch waited ${elapsed}s of a 30s grace"
  pass "a terminal status with a newer turn-ended marker ends the grace early"
}

test_paused_status_with_newer_marker_ends_grace_early() {
  local elapsed
  elapsed=$(run_batch early-paused 30 't1:paused: waiting on checks:marker')
  [ "$elapsed" -le 24 ] || fail "settled paused batch waited ${elapsed}s of a 30s grace"
  pass "a paused status with a newer turn-ended marker ends the grace early"
}

test_terminal_status_without_marker_waits_full_grace() {
  local elapsed
  elapsed=$(run_batch no-marker 5 't1:done: finished')
  [ "$elapsed" -ge 4 ] || fail "a status with no marker ended the grace after ${elapsed}s of 5s"
  pass "a harness that writes no turn-ended marker keeps the full grace"
}

test_one_unsettled_status_keeps_full_grace() {
  local elapsed
  elapsed=$(run_batch one-unsettled 5 't1:done: finished:marker' 't2:blocked: stuck')
  [ "$elapsed" -ge 4 ] || fail "a batch with an unsettled status ended after ${elapsed}s of 5s"
  pass "one terminal status without a newer marker keeps the full grace"
}

test_status_written_during_grace_keeps_full_grace() {
  local elapsed
  elapsed=$(LATE_STATUS='t2:done: finished late' run_batch late-status 15 't1:done: finished:marker')
  [ "$elapsed" -ge 12 ] || fail "a status written during the grace ended it after ${elapsed}s of 15s"
  pass "a terminal status written during the grace without a marker keeps the full grace"
}

test_nonterminal_status_alone_keeps_full_grace() {
  local elapsed
  elapsed=$(run_batch nonterminal 5 't1:working: building:marker')
  [ "$elapsed" -ge 4 ] || fail "a working status ended the grace after ${elapsed}s of 5s"
  pass "a non-terminal status with a marker does not end the grace"
}

test_fractional_grace_keeps_single_sleep() {
  local elapsed
  elapsed=$(run_batch fractional 3.5 't1:done: finished:marker')
  [ "$elapsed" -ge 3 ] || fail "a fractional grace ended after ${elapsed}s of 3.5s"
  pass "a fractional grace keeps the single sleep"
}

test_terminal_status_with_newer_marker_ends_grace_early
test_paused_status_with_newer_marker_ends_grace_early
test_terminal_status_without_marker_waits_full_grace
test_one_unsettled_status_keeps_full_grace
test_status_written_during_grace_keeps_full_grace
test_nonterminal_status_alone_keeps_full_grace
test_fractional_grace_keeps_single_sleep
