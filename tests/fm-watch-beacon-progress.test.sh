#!/usr/bin/env bash
# tests/fm-watch-beacon-progress.test.sh - the watcher liveness beacon tracks
# cycle PROGRESS, not whole-cycle length, and every beacon reader judges the
# cadence the watcher itself declares.
#
# One supervision cycle runs the pending-reply sweep, the per-window stale loop,
# the heartbeat scan, and the check sweep before it reaches its terminal wait,
# and each of those shells out per unit. On a large home a healthy cycle outlived
# the 300-second guard grace with the beacon untouched: the turn-end guard then
# reported "supervision is off" for a live, working watcher, and a successor arm
# refused that same holder as stale until FM_WATCHER_STALL_BOUND, so a working
# cycle both raised a false alarm and blocked its own replacement
# (docs/turnend-guard.md "Cycle progress keeps the beacon fresh").
#
# These are real-process tests: a real bin/fm-watch.sh runs a deliberately long
# check sweep in an isolated home, a real bin/fm-guard.sh and bin/fm-watch-arm.sh
# judge it, and real stalled holders prove the alarm and the eviction still fire.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
GUARD="$ROOT/bin/fm-guard.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-beacon-progress)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=
HOLDER_PID=

# A check that is genuinely slow but silent: an empty result keeps the sweep
# walking the remaining checks instead of waking the cycle, which is what makes
# one cycle long here.
SLOW_CHECK_SOURCE='#!/usr/bin/env bash
sleep 2
exit 0
'

make_home() {  # <name> -> echoes the case dir
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/config" \
    "$TMP_ROOT/$dir/home/data" "$TMP_ROOT/$dir/root"
  printf '%s\n' "$TMP_ROOT/$dir"
}

case_home() {  # <case-dir>
  printf '%s/home\n' "$1"
}

case_root() {  # <case-dir>
  printf '%s/root\n' "$1"
}

age_of_beacon() {  # <path>
  local path=$1 now m
  now=$(date +%s)
  m=$(stat -c %Y "$path" 2>/dev/null) || m=$(stat -f %m "$path" 2>/dev/null) \
    || { printf '999999\n'; return 0; }
  printf '%s\n' "$(( now - m ))"
}

backdate_beacon() {  # <home> <seconds-in-the-past>
  local home=$1 secs=$2
  fm_touch_epoch "$(( $(date +%s) - secs ))" "$home/state/.last-watcher-beat"
}

stop_pid() {  # <pid>
  local pid=$1 i=0
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

register_slow_checks() {  # <home> <count>
  local home=$1 count=$2 i
  i=0
  while [ "$i" -lt "$count" ]; do
    i=$((i + 1))
    printf '%s' "$SLOW_CHECK_SOURCE" > "$home/state/slow-$i.check.sh"
    chmod 0700 "$home/state/slow-$i.check.sh"
    FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null \
      || fail "could not register fixture check slow-$i"
  done
}

# Start the real watcher against a home whose check sweep keeps one cycle busy
# far longer than the grace the readers below are given.
start_slow_cycle_watcher() {  # <home> <out> <grace-seconds>
  local home=$1 out=$2 grace=$3 i
  fm_test_track_watcher_state "$home/state"
  FM_HOME="$home" FM_GUARD_GRACE="$grace" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$home/state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "fixture watcher did not take the lock: $(cat "$out" 2>/dev/null)"
}

run_guard() {  # <case-dir> <grace>
  local dir=$1 grace=$2
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE="$grace" \
    FM_SUPERVISION_MODEL=persistent \
    "$GUARD" 2>&1
}

run_guard_derived() {  # <case-dir> -- no explicit grace
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_SUPERVISION_MODEL=persistent \
    "$GUARD" 2>&1
}

# Record a live, identity-matched lock holder for a process the test controls, so
# the readers below see a genuine holder whose beacon the test backdates.
record_live_holder() {  # <home> <pid>
  local home=$1 pid=$2 identity
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not compute fixture holder identity"
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
}

# A live holder whose recorded beacon is 20s old: stale past a small explicit
# grace, inside a generous explicit hard bound.
start_stalled_holder() {  # <home>
  local home=$1
  fm_test_track_watcher_state "$home/state"
  # Supervision need without a window: an in-flight task record, so the guard
  # judges the beacon instead of exiting silently on an idle home.
  fm_write_meta "$home/state/task.meta" "kind=ship"
  # The holder must be a live process the readers can identity-match.
  sleep 300 &
  HOLDER_PID=$!
  record_live_holder "$home" "$HOLDER_PID"
  : > "$home/state/.last-watcher-beat"
  backdate_beacon "$home" 20
}

run_arm() {  # <home> [extra env...] -> echoes arm output, nonzero status preserved
  local home=$1
  shift
  env FM_HOME="$home" "$@" "$WATCH_ARM" 2>&1
}

test_progress_refresh_is_throttled_and_inert_outside_a_watcher() {
  local dir home beat
  dir=$(make_home progress-entry)
  home=$(case_home "$dir")
  beat="$home/state/.last-watcher-beat"
  bash -c '
    set -u
    . "$1"
    beat=$2
    FM_WATCH_BEACON_PATH=$beat
    fm_watch_beacon_progress || exit 1
    [ -e "$beat" ] || exit 2
    first=$_FM_BEACON_TICK_AT
    fm_watch_beacon_progress || exit 3
    [ "$_FM_BEACON_TICK_AT" = "$first" ] || exit 4
    exit 0
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$beat" \
    || fail "progress refresh did not touch the beacon or did not throttle the repeat"
  [ "$(age_of_beacon "$beat")" -le 1 ] \
    || fail "a fresh progress tick left the beacon older than 1s"
  pass "a progress tick refreshes the watcher beacon and throttles tight loops"

  fm_touch_epoch "$(( $(date +%s) - 20 ))" "$beat"
  bash -c '
    set -u
    . "$1"
    beat=$2
    # A stale beacon must stay stale when no watcher owns this process.
    unset FM_WATCH_BEACON_PATH
    before=$(fm_path_age "$beat")
    [ "$before" -ge 20 ] || exit 2
    fm_watch_beacon_progress || exit 3
    [ "$(fm_path_age "$beat")" -ge "$before" ] || exit 4
    exit 0
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$beat" \
    || fail "progress refresh was not inert outside a watcher"
  pass "progress refresh is inert outside a watcher, so no library invents liveness"
}

test_derived_grace_follows_the_poll_cadence() {
  local dir out
  dir=$(make_home derived-grace)
  # A long-poll home: the derived default grows past the historical 300s floor so
  # the guard, the arm, and the watcher judge one cadence.
  out=$(FM_POLL=300 run_guard_derived "$dir")
  # No supervision need in this home, so the guard exits silently; the assertion
  # is on the derivation itself, which every reader shares.
  [ -z "$out" ] || fail "an idle home printed guard output: $out"
  out=$(bash -c '. "$1"; FM_POLL=300; fm_beacon_grace' _ "$ROOT/bin/fm-wake-lib.sh")
  assert_equals 360 "$out" "derived beacon grace for a 300s poll"
  out=$(bash -c '. "$1"; FM_POLL=15; fm_beacon_grace' _ "$ROOT/bin/fm-wake-lib.sh")
  assert_equals 300 "$out" "derived beacon grace floor for a short poll"
  out=$(bash -c '. "$1"; FM_POLL=300; FM_GUARD_GRACE=42; fm_beacon_grace' _ "$ROOT/bin/fm-wake-lib.sh")
  assert_equals 42 "$out" "an explicit FM_GUARD_GRACE still wins over the derivation"
  pass "the shared beacon grace derives from the poll cadence and honours an explicit override"
}

test_standalone_supervision_uses_derived_grace() {
  local dir home
  dir=$(make_home standalone-supervision)
  home=$(case_home "$dir")
  fm_write_meta "$home/state/task.meta" "kind=ship"
  : > "$home/state/.last-watcher-beat"
  backdate_beacon "$home" 320
  FM_HOME="$home" bash -c '
    set -eu
    unset FM_GUARD_GRACE
    . "$1"
    FM_POLL=300
    fm_supervision_status "$2"
    [ "$FM_SUP_WATCHER_FRESH" = true ]
    fm_supervision_needed "$2"
    if fm_supervision_unhealthy "$2"; then exit 1; fi
    FM_POLL=15
    fm_supervision_status "$2"
    [ "$FM_SUP_WATCHER_FRESH" = false ]
    fm_supervision_unhealthy "$2"
  ' _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state" \
    || fail "standalone supervision did not distinguish the 360s and 300s grace windows"
  pass "standalone supervision predicates share the poll-derived grace"
}

test_progress_throttle_has_a_fixed_interval() {
  local dir home beat
  dir=$(make_home fixed-progress-interval)
  home=$(case_home "$dir")
  beat="$home/state/.last-watcher-beat"
  FM_HOME="$home" FM_BEACON_TICK_INTERVAL=999999 bash -c '
    set -eu
    . "$1"
    fm_watch_beacon_tick "$2" 999999
    SECONDS=$((SECONDS + 2))
    touch -t 200001010000 "$2"
    fm_watch_beacon_tick "$2" 999999
    [ "$(fm_path_age "$2")" -le 1 ]
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$beat" \
    || fail "an optional interval suppressed real progress refreshes"
  pass "progress refresh keeps a fixed cadence regardless of unused interval inputs"
}

test_working_long_cycle_keeps_the_beacon_fresh() {
  local dur home out grace=4 max_age i age
  dur=$(make_home working-cycle)
  home=$(case_home "$dur")
  out="$dur/watch.out"
  # Five 2s checks make one cycle about five times the grace below.
  register_slow_checks "$home" 5
  start_slow_cycle_watcher "$home" "$out" "$grace"
  max_age=0
  i=0
  while [ "$i" -lt 60 ]; do
    age=$(age_of_beacon "$home/state/.last-watcher-beat")
    [ "$age" -le "$max_age" ] || max_age=$age
    sleep 0.2
    i=$((i + 1))
  done
  stop_pid "$SEED_PID"
  [ "$max_age" -lt "$grace" ] \
    || fail "a working cycle aged the beacon to ${max_age}s past the ${grace}s grace"
  pass "a live watcher mid-sweep refreshes its beacon, so a long cycle never reads as dead"
}

test_working_long_cycle_raises_no_alarm_and_accepts_a_successor() {
  local dir home out arm_out arm_pid i
  dir=$(make_home working-guard)
  home=$(case_home "$dir")
  out="$dir/watch.out"
  arm_out="$dir/arm.out"
  register_slow_checks "$home" 5
  start_slow_cycle_watcher "$home" "$out" 4
  sleep 2
  case "$(run_guard "$dir" 4)" in
    *"WATCHER DOWN"*) fail "a working cycle raised the watcher-down banner" ;;
  esac
  pass "the pull guard stays silent while a live watcher works through a long sweep"

  env FM_HOME="$home" FM_GUARD_GRACE=4 FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT=5 "$WATCH_ARM" > "$arm_out" 2>&1 &
  arm_pid=$!
  i=0
  while [ "$i" -lt 120 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$arm_out" 2>/dev/null && break
    grep -qF "watcher: FAILED" "$arm_out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  stop_pid "$arm_pid"
  grep -qF "watcher: attached pid=$SEED_PID" "$arm_out" \
    || fail "a successor could not attach to the working cycle: $(cat "$arm_out")"
  pass "a successor attaches to a working cycle instead of refusing or replacing it"
  stop_pid "$SEED_PID"
}

test_stalled_holder_still_trips_the_banner() {
  local dir home out
  dir=$(make_home stalled-banner)
  home=$(case_home "$dir")
  start_stalled_holder "$home"
  out=$(run_guard "$dir" 7)
  stop_pid "$HOLDER_PID"
  case "$out" in
    *"WATCHER DOWN"*) ;;
    *) fail "a genuinely stalled beacon no longer trips the banner: $out" ;;
  esac
  case "$out" in
    *"grace 7s"*) ;;
    *) fail "the banner did not judge the explicit FM_GUARD_GRACE of 7s: $out" ;;
  esac
  pass "a stalled beacon still raises the banner, judged with the explicit grace"
}

test_stalled_holder_is_evicted_only_past_the_hard_bound() {
  local dir home out holder
  dir=$(make_home stalled-evict)
  home=$(case_home "$dir")
  start_stalled_holder "$home"
  holder=$HOLDER_PID
  # 20s stale: past the 7s grace, far inside this explicit 60s hard bound.
  out=$(run_arm "$home" FM_GUARD_GRACE=7 FM_WATCHER_STALL_BOUND=60 FM_ARM_CONFIRM_TIMEOUT=5)
  kill -0 "$holder" 2>/dev/null \
    || fail "a holder inside the explicit hard bound was killed: $out"
  case "$out" in
    *"replaced stalled pid"*) fail "a holder inside the hard bound was replaced: $out" ;;
  esac
  pass "an explicit FM_WATCHER_STALL_BOUND keeps a merely slow holder in place"

  # Past a 5s hard bound the same holder must be evicted and replaced.
  backdate_beacon "$home" 30
  fm_test_track_watcher_state "$home/state"
  env FM_HOME="$home" FM_GUARD_GRACE=7 FM_WATCHER_STALL_BOUND=5 \
    FM_ARM_CONFIRM_TIMEOUT=5 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$dir/evict.out" 2>&1 &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 200 ]; do
    grep -qF "replaced stalled pid $holder" "$dir/evict.out" 2>/dev/null && break
    grep -qF "watcher: FAILED" "$dir/evict.out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  stop_pid "$ARM_PID"
  if [ -e "$home/state/.watch.lock/pid" ]; then
    stop_pid "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)"
  fi
  grep -qF "replaced stalled pid $holder" "$dir/evict.out" \
    || fail "a beacon past the explicit hard bound was not evicted: $(cat "$dir/evict.out")"
  kill -0 "$holder" 2>/dev/null \
    && fail "the stalled holder outlived the eviction"
  pass "a genuinely stalled holder is still evicted and replaced past the hard bound"
}

test_explicit_grace_overrides_the_derived_default() {
  local dir home out
  dir=$(make_home grace-override)
  home=$(case_home "$dir")
  start_stalled_holder "$home"
  # The same 20s-stale beacon reads fresh under 60s and stale under 7s.
  out=$(run_guard "$dir" 60)
  [ -z "$out" ] || fail "an explicit 60s grace did not read the 20s-stale beacon as fresh: $out"
  out=$(run_guard "$dir" 7)
  case "$out" in
    *"WATCHER DOWN"*) ;;
    *) fail "an explicit 7s grace did not read the 20s-stale beacon as stale: $out" ;;
  esac
  stop_pid "$HOLDER_PID"
  pass "an explicit FM_GUARD_GRACE wins over the derived default in both directions"
}

test_explicit_heartbeat_cadence_still_governs() {
  local dir home out i
  dir=$(make_home heartbeat-override)
  home=$(case_home "$dir")
  out="$dir/watch.out"
  # An idle fleet's heartbeat is absorbed, but it still records its schedule, so
  # an explicit FM_HEARTBEAT remains in force next to the progress refresh.
  fm_test_track_watcher_state "$home/state"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 "$WATCH" > "$out" 2>&1 &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 150 ]; do
    [ -e "$home/state/.last-heartbeat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  stop_pid "$SEED_PID"
  [ -e "$home/state/.last-heartbeat" ] \
    || fail "an explicit one-second FM_HEARTBEAT never ran: $(cat "$out")"
  pass "an explicit FM_HEARTBEAT cadence still governs the heartbeat"
}

fm_test_run \
  test_progress_refresh_is_throttled_and_inert_outside_a_watcher \
  test_derived_grace_follows_the_poll_cadence \
  test_standalone_supervision_uses_derived_grace \
  test_progress_throttle_has_a_fixed_interval \
  test_working_long_cycle_keeps_the_beacon_fresh \
  test_working_long_cycle_raises_no_alarm_and_accepts_a_successor \
  test_stalled_holder_still_trips_the_banner \
  test_stalled_holder_is_evicted_only_past_the_hard_bound \
  test_explicit_grace_overrides_the_derived_default \
  test_explicit_heartbeat_cadence_still_governs
