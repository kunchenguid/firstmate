#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

wait_for_marker_file() {  # <path> <pid> <label>
  local path=$1 pid=$2 label=$3 i=0
  while [ "$i" -lt 120 ]; do
    [ -e "$path" ] && return 0
    is_live_non_zombie "$pid" || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fail "$label"
}

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

test_arm_parks_while_away_mode_owns_supervision() {
  local dir state fakebin out armout lock_pid arm_pid i
  dir=$(make_case afk-park)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  lock_pid=$(cat "$state/.watch.lock/pid")
  date '+%s' > "$state/.afk"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_AFK_POLL=0.1 \
    "$WATCH_ARM" --restart > "$armout" 2>&1 &
  ARM_PID=$!
  arm_pid=$ARM_PID
  sleep 0.5

  is_live_non_zombie "$ARM_PID" || fail "away-mode arm completed instead of parking"
  [ ! -s "$armout" ] || fail "parked arm emitted output: $(cat "$armout")"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
    || fail "away-mode arm took the watcher singleton away from the daemon's watcher"
  kill -0 "$lock_pid" 2>/dev/null \
    || fail "away-mode arm killed the daemon's watcher child"

  rm -f "$state/.afk"
  i=0
  while [ "$i" -lt 120 ]; do
    grep -q '^watcher: started' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -q '^watcher: started' "$armout" \
    || fail "parked arm did not resume a normal cycle after away mode ended: $(cat "$armout")"
  if [ "$ARM_PID" != "$arm_pid" ] || ! is_live_non_zombie "$arm_pid"; then
    fail "parked arm did not resume from the same tracked process"
  fi

  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  pass "watch-arm: away mode parks the tracked arm and it resumes after return"
}

test_restart_rechecks_away_mode_before_signaling() {
  local dir state fakebin out armout lock_pid ready release once real_cat status i
  dir=$(make_case afk-restart-before-signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  ready="$dir/cat.ready"
  release="$dir/cat.release"
  once="$dir/cat.once"
  real_cat=$(command -v cat)
  start_seed_watcher "$state" "$fakebin" "$out"
  lock_pid=$SEED_PID
  printf '%s\n' "$real_cat" > "$fakebin/real-cat-path"
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "${FM_RACE_LOCK_PID:-}" ] && [ ! -e "${FM_RACE_ONCE:-/dev/null}" ]; then
  : > "$FM_RACE_ONCE"
  : > "$FM_RACE_READY"
  while [ ! -e "$FM_RACE_RELEASE" ]; do sleep 0.02; done
fi
IFS= read -r real_cat < "${0%/*}/real-cat-path"
exec "${FM_REAL_CAT:-$real_cat}" "$@"
SH
  chmod +x "$fakebin/cat"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_REAL_CAT="$real_cat" \
    FM_RACE_LOCK_PID="$state/.watch.lock/pid" FM_RACE_ONCE="$once" \
    FM_RACE_READY="$ready" FM_RACE_RELEASE="$release" \
    "$WATCH_ARM" --restart > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_marker_file "$ready" "$ARM_PID" "restart did not reach the lock-holder read boundary"
  date '+%s' > "$state/.afk"
  : > "$release"
  i=0
  while [ "$i" -lt 40 ] && is_live_non_zombie "$ARM_PID"; do
    sleep 0.1
    i=$((i + 1))
  done

  is_live_non_zombie "$ARM_PID" || fail "restart completed instead of parking before signaling"
  [ ! -s "$armout" ] || fail "restart emitted output while parked: $(cat "$armout")"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
    || fail "restart replaced the watcher lock after away mode began"
  kill -0 "$lock_pid" 2>/dev/null \
    || fail "restart killed the watcher after away mode began"

  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 30
  status=$?
  expect_code 143 "$status" "TERM must stop a parked arm promptly"
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  pass "watch-arm: restart parks before signaling and remains interruptible"
}

test_restart_rechecks_away_mode_before_fork() {
  local dir state fakebin out armout old_pid daemon_pid ready release once real_mktemp i
  dir=$(make_case afk-restart-before-fork)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  ready="$dir/mktemp.ready"
  release="$dir/mktemp.release"
  once="$dir/mktemp.once"
  real_mktemp=$(command -v mktemp)
  start_seed_watcher "$state" "$fakebin" "$out"
  old_pid=$SEED_PID
  printf '%s\n' "$real_mktemp" > "$fakebin/real-mktemp-path"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  */.watch-arm-output.*)
    if [ ! -e "${FM_RACE_ONCE:-/dev/null}" ]; then
      : > "$FM_RACE_ONCE"
      : > "$FM_RACE_READY"
      while [ ! -e "$FM_RACE_RELEASE" ]; do sleep 0.02; done
    fi
    ;;
esac
IFS= read -r real_mktemp < "${0%/*}/real-mktemp-path"
exec "${FM_REAL_MKTEMP:-$real_mktemp}" "$@"
SH
  chmod +x "$fakebin/mktemp"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_REAL_MKTEMP="$real_mktemp" \
    FM_RACE_ONCE="$once" FM_RACE_READY="$ready" FM_RACE_RELEASE="$release" \
    "$WATCH_ARM" --restart > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_marker_file "$ready" "$ARM_PID" "restart did not reach the pre-fork boundary"
  wait "$old_pid" 2>/dev/null || true
  date '+%s' > "$state/.afk"
  start_seed_watcher "$state" "$fakebin" "$out"
  daemon_pid=$SEED_PID
  : > "$release"
  i=0
  while [ "$i" -lt 20 ]; do
    is_live_non_zombie "$ARM_PID" || fail "restart completed instead of parking before fork"
    sleep 0.1
    i=$((i + 1))
  done

  [ ! -s "$armout" ] || fail "restart emitted output while parked before fork: $(cat "$armout")"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$daemon_pid" ] \
    || fail "restart took the singleton from the daemon watcher before fork"
  kill -0 "$daemon_pid" 2>/dev/null \
    || fail "restart disturbed the daemon watcher before fork"

  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  pass "watch-arm: restart parks immediately before watcher fork"
}

test_attached_arm_stands_down_after_away_mode_delivery() {
  local dir state fakebin out armout status
  dir=$(make_case afk-attached-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  date '+%s' > "$state/.afk"
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  wait_for_exit "$ARM_PID" 120
  status=$?

  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" 2>/dev/null \
    || fail "attached arm did not classify the delivered wake before standing down"
  expect_code 0 "$status" "attached arm must stand down cleanly after its away-mode delivery"
  grep -q '^watcher: stood-down' "$armout" \
    || fail "attached arm did not return the stand-down line: $(cat "$armout")"
  ! grep -qE '^(signal:|stale:|check:|heartbeat)' "$armout" \
    || fail "attached arm returned its away-mode wake: $(cat "$armout")"
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "attached arm lost the durable away-mode wake"

  pass "watch-arm: an attached arm stands down after an away-mode delivery"
}

# Wait until the arm's own forked watcher child holds this home's singleton.
wait_for_owned_watcher() {  # <state> <arm-pid> <message>
  local state=$1 arm=$2 message=$3 i=0
  while [ "$i" -lt 120 ]; do
    [ -s "$state/.watch.lock/pid" ] && [ -e "$state/.last-watcher-beat" ] && return 0
    is_live_non_zombie "$arm" || fail "$message (arm exited early)"
    sleep 0.1
    i=$((i + 1))
  done
  fail "$message"
}

test_owned_arm_stands_down_after_away_mode_delivery_record() {
  local dir state fakebin armout output_file status
  dir=$(make_case afk-owned-delivery-record)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=1 \
    "$WATCH_ARM" > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_owned_watcher "$state" "$ARM_PID" "delivery-record arm never established its own watcher cycle"

  output_file=
  for output_file in "$state"/.watch-arm-output.*; do
    [ -e "$output_file" ] && break
    output_file=
  done
  [ -n "$output_file" ] || fail "owned arm did not expose its child capture"
  rm -f "$output_file"
  date '+%s' > "$state/.afk"
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$ARM_PID" 200
  status=$?

  grep -q 'reason=clean-exit-delivered-wake' "$state/.watch-cycle-exits.log" 2>/dev/null \
    || fail "owned arm did not classify its delivery-record wake before standing down"
  expect_code 0 "$status" "owned arm must stand down cleanly after resolving its away-mode delivery record"
  grep -q '^watcher: stood-down' "$armout" \
    || fail "owned arm did not return the stand-down line: $(cat "$armout")"
  ! grep -qE '^(signal:|stale:|check:|heartbeat)' "$armout" \
    || fail "owned arm returned its delivery-record wake under away mode: $(cat "$armout")"
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "owned arm lost the durable delivery-record wake"

  pass "watch-arm: an owned arm stands down after an away-mode delivery record"
}

# The adapterless wake path: for a Grok tracked background task or a manual
# probe there is no adapter to suppress delivery, so the arm's own return value
# IS the wake. An arm already running when away mode begins must therefore hand
# back the stand-down line instead of its cycle's reason.
test_live_arm_stands_down_when_away_mode_begins_mid_cycle() {
  local dir state fakebin armout status
  dir=$(make_case afk-live-arm-mid-cycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=10 \
    "$WATCH_ARM" > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_owned_watcher "$state" "$ARM_PID" "arm never established its own watcher cycle"

  # Away mode begins while this arm's watcher child is already live, then a real
  # captain-relevant status change drives a real wake through that child.
  date '+%s' > "$state/.afk"
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$ARM_PID" 200
  status=$?

  grep -q 'reason=actionable-signal' "$state/.watch-cycle-exits.log" 2>/dev/null \
    || fail "live arm did not classify its away-mode wake before standing down"
  expect_code 0 "$status" "a live arm must stand down cleanly when away mode begins mid-cycle"
  grep -q '^watcher: stood-down' "$armout" \
    || fail "live arm did not stand down after away mode began: $(cat "$armout")"
  ! grep -qE '^(signal:|stale:|check:|heartbeat)' "$armout" \
    || fail "live arm handed a wake back to its caller under away mode: $(cat "$armout")"
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the suppressed wake was not preserved in the durable queue"
  pass "watch-arm: a live arm stands down instead of returning its wake when away mode begins"
}

# The same path with away mode off must still return the wake.
test_live_arm_still_reports_its_wake_with_away_mode_off() {
  local dir state fakebin armout status
  dir=$(make_case afk-live-arm-control)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=10 \
    "$WATCH_ARM" > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_owned_watcher "$state" "$ARM_PID" "control arm never established its own watcher cycle"

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$ARM_PID" 200
  status=$?

  expect_code 0 "$status" "an ordinary arm cycle must still close successfully"
  grep -q '^signal:' "$armout" \
    || fail "arm did not report its wake with away mode off: $(cat "$armout")"
  pass "watch-arm: an ordinary arm still returns its wake when away mode is off"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_arm_parks_while_away_mode_owns_supervision
test_restart_rechecks_away_mode_before_signaling
test_restart_rechecks_away_mode_before_fork
test_attached_arm_stands_down_after_away_mode_delivery
test_owned_arm_stands_down_after_away_mode_delivery_record
test_live_arm_stands_down_when_away_mode_begins_mid_cycle
test_live_arm_still_reports_its_wake_with_away_mode_off
