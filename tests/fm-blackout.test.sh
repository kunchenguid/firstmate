#!/usr/bin/env bash
# Behavior tests for the overnight "quiet hours" blackout.
#
# The watcher process is effectively free; the cost is that every WAKE starts a
# full firstmate LLM turn. The captain wants ZERO autonomous wakes between 18:00
# and 05:00 America/New_York, so the blackout is enforced in code across four
# surfaces:
#   PREDICATE  - bin/fm-blackout-lib.sh: fm_in_blackout over an injectable clock,
#                the boundaries (18:00 => blackout, 05:00 => active), DST, and
#                configurable bounds.
#   WATCHER    - bin/fm-watch.sh exits cleanly with FM_BLACKOUT_EXIT_CODE when it
#                crosses into the window (non-afk), and does NOT under afk.
#   ARM        - bin/fm-watch-arm.sh schedules a zero-token sleeper during
#                blackout instead of an active watcher, is singleton-safe, and
#                releases its lock on teardown.
#   GUARD      - bin/fm-guard.sh suppresses the WATCHER DOWN banner during
#                blackout (an absent watcher is expected) but keeps its
#                queued-wakes and worktree-tangle guards in both windows.
#   DAEMON     - bin/fm-supervise-daemon.sh defers away-mode injection during
#                blackout so away mode also burns zero overnight tokens.
#
# All hermetic: the injectable clock FM_BLACKOUT_NOW_EPOCH removes any dependence
# on the real time, and the timezone math relies only on the system tz database.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-blackout-lib.sh
. "$ROOT/bin/fm-blackout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-blackout)
fm_git_identity fmtest fmtest@example.invalid

# Verified epochs for America/New_York wall-clock boundaries. Winter (EST, UTC-5)
# and summer (EDT, UTC-4) 05:00-local map to DIFFERENT UTC hours (10 vs 09), so a
# predicate that lands both on "active" is genuinely DST-aware rather than doing
# fixed UTC-offset arithmetic.
EPOCH_WINTER_0500=1704103200   # 2024-01-01 05:00 EST  (UTC 10:00) -> active boundary
EPOCH_WINTER_0459=1704103140   # 2024-01-01 04:59 EST                -> blackout
EPOCH_WINTER_1800=1704150000   # 2024-01-01 18:00 EST  (UTC 23:00) -> blackout boundary
EPOCH_WINTER_1759=1704149940   # 2024-01-01 17:59 EST                -> active
EPOCH_WINTER_0100=1704088800   # 2024-01-01 01:00 EST                -> blackout (mid-window)
EPOCH_WINTER_1200=1704110400   # 2024-01-01 07:00 EST                -> active (mid-window)
EPOCH_SUMMER_0500=1719824400   # 2024-07-01 05:00 EDT  (UTC 09:00) -> active boundary
EPOCH_SUMMER_0400=1719820800   # 2024-07-01 04:00 EDT                -> blackout

# assert_blackout <epoch> <expect: blackout|active> <msg> [extra env "K=V" ...]
# The feature is OFF by default, so these window cases enable it explicitly; a
# later extra "K=V" (e.g. FM_BLACKOUT_ENABLED=0) still wins over that default.
assert_blackout() {
  local epoch=$1 expect=$2 msg=$3 got
  shift 3
  if env FM_BLACKOUT_ENABLED=1 "$@" FM_BLACKOUT_NOW_EPOCH="$epoch" bash -c \
    ". '$ROOT/bin/fm-blackout-lib.sh'; fm_in_blackout"; then
    got=blackout
  else
    got=active
  fi
  [ "$got" = "$expect" ] || fail "$msg: expected $expect, got $got (epoch $epoch)"
}

# --- PREDICATE: boundaries, mid-window, DST ----------------------------------

test_predicate_boundaries() {
  # Exact boundaries: 05:00 is the first ACTIVE minute, 18:00 the first blackout.
  assert_blackout "$EPOCH_WINTER_0500" active   "05:00 ET is active (boundary)"
  assert_blackout "$EPOCH_WINTER_0459" blackout "04:59 ET is blackout"
  assert_blackout "$EPOCH_WINTER_1800" blackout "18:00 ET is blackout (boundary)"
  assert_blackout "$EPOCH_WINTER_1759" active   "17:59 ET is active"
  # Mid-window sanity.
  assert_blackout "$EPOCH_WINTER_0100" blackout "01:00 ET is blackout"
  assert_blackout "$EPOCH_WINTER_1200" active   "midday ET is active"
  pass "predicate: 18:00 => blackout, 05:00 => active, and the window between"
}

test_predicate_dst() {
  # Same 05:00-LOCAL boundary in summer, despite a different UTC offset, is still
  # the active boundary; 04:00 local is still blackout. Proves DST awareness.
  assert_blackout "$EPOCH_SUMMER_0500" active   "05:00 EDT is active (DST boundary)"
  assert_blackout "$EPOCH_SUMMER_0400" blackout "04:00 EDT is blackout (DST)"
  # And the reported local hour is 5 in BOTH seasons even though the UTC hour
  # differs (10 in winter, 9 in summer): the tz math, not a fixed offset, decides.
  local wh sh
  wh=$(FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_0500" fm_blackout_hour)
  sh=$(FM_BLACKOUT_NOW_EPOCH="$EPOCH_SUMMER_0500" fm_blackout_hour)
  [ "$wh" = 5 ] || fail "winter 05:00 ET hour: expected 5, got $wh"
  [ "$sh" = 5 ] || fail "summer 05:00 ET hour: expected 5, got $sh"
  pass "predicate: EST/EDT boundary is DST-aware (tz math, not fixed offset)"
}

test_predicate_configurable() {
  # A custom, non-wrapping day window [09, 17): 07:00 ET is outside it -> active.
  assert_blackout "$EPOCH_WINTER_1200" active "custom [9,17): 07:00 ET is outside" \
    FM_BLACKOUT_START_HOUR=9 FM_BLACKOUT_END_HOUR=17
  # 07:00 ET with a [6,8) window is inside -> blackout.
  assert_blackout "$EPOCH_WINTER_1200" blackout "custom [6,8): 07:00 ET is inside" \
    FM_BLACKOUT_START_HOUR=6 FM_BLACKOUT_END_HOUR=8
  # A different timezone shifts the wall clock: 05:00 EST is 02:00 in US/Pacific,
  # which is inside the default overnight window there.
  assert_blackout "$EPOCH_WINTER_0500" blackout "TZ override: 02:00 PT is blackout" \
    FM_BLACKOUT_TZ=America/Los_Angeles
  pass "predicate: START/END hours and TZ are configurable"
}

test_predicate_broken_clock() {
  # A garbage injected clock must never wedge supervision: it is sanitized back to
  # the real wall clock (a numeric epoch), and the derived hour stays a valid
  # 0-23, so the predicate can never crash or lock into a permanent blackout.
  local now h
  now=$(FM_BLACKOUT_NOW_EPOCH=not-a-number fm_blackout_now_epoch)
  case "$now" in ''|*[!0-9]*) fail "broken clock: now not sanitized to a numeric epoch, got '$now'" ;; esac
  h=$(FM_BLACKOUT_NOW_EPOCH=not-a-number fm_blackout_hour)
  case "$h" in ''|*[!0-9]*) fail "broken clock: hour not numeric, got '$h'" ;; esac
  [ "$h" -ge 0 ] && [ "$h" -le 23 ] || fail "broken clock: hour out of range, got '$h'"
  pass "predicate: a broken injected clock is sanitized to the real clock (never wedges)"
}

# --- OFF BY DEFAULT: the feature is a complete no-op unless enabled -----------

test_off_by_default() {
  # No enablement anywhere: even deep in the default blackout window the predicate
  # must report ACTIVE, so committed behavior is unchanged for anyone not opted in.
  local got
  if FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_0100" bash -c \
    ". '$ROOT/bin/fm-blackout-lib.sh'; fm_in_blackout"; then got=blackout; else got=active; fi
  [ "$got" = active ] || fail "off-by-default: disabled must never be in blackout, got $got"
  # Truthy variants of the switch enable; falsey variants stay a no-op.
  assert_blackout "$EPOCH_WINTER_0100" blackout "enabled=1 is in blackout at 01:00 ET"
  assert_blackout "$EPOCH_WINTER_0100" active   "enabled=0 is a no-op" FM_BLACKOUT_ENABLED=0
  assert_blackout "$EPOCH_WINTER_0100" active   "enabled=false is a no-op" FM_BLACKOUT_ENABLED=false
  assert_blackout "$EPOCH_WINTER_0100" active   "enabled=off is a no-op" FM_BLACKOUT_ENABLED=off
  assert_blackout "$EPOCH_WINTER_0100" blackout "enabled=true enables" FM_BLACKOUT_ENABLED=true
  pass "predicate: OFF by default; only a truthy master switch enables the blackout"
}

# --- CONFIG FILE: opt-in via config/blackout.env, env-wins -------------------

test_config_file_enable() {
  local home="$TMP_ROOT/cfg-home" got
  mkdir -p "$home/config" "$home/state"
  # The shipped example is a working, enabled config; copying it opts a home in.
  cp "$ROOT/docs/examples/blackout.env" "$home/config/blackout.env"

  got=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_0100" \
    bash -c ". '$ROOT/bin/fm-blackout-lib.sh'; fm_in_blackout && echo blackout || echo active")
  [ "$got" = blackout ] || fail "config file did not enable the blackout, got $got"

  # Explicit environment overrides the file (env-wins precedence).
  got=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BLACKOUT_ENABLED=0 \
    FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_0100" \
    bash -c ". '$ROOT/bin/fm-blackout-lib.sh'; fm_in_blackout && echo blackout || echo active")
  [ "$got" = active ] || fail "env FM_BLACKOUT_ENABLED=0 did not override the config file, got $got"
  pass "config: config/blackout.env opts a home in; explicit env still wins"
}

# --- EXTEND OVERRIDE: evening extension defers the window --------------------

test_extend_override_predicate() {
  local state="$TMP_ROOT/ext-pred/state" got
  mkdir -p "$state"
  # Enabled, deep in blackout (19:00 ET), but a FUTURE override (21:00) => active.
  printf '%s\n' 1704160800 > "$state/blackout-override"   # 2024-01-01 21:00 EST
  got=$(FM_STATE_OVERRIDE="$state" FM_BLACKOUT_ENABLED=1 FM_BLACKOUT_NOW_EPOCH=1704153600 \
    bash -c ". '$ROOT/bin/fm-blackout-lib.sh'; fm_in_blackout && echo blackout || echo active")
  [ "$got" = active ] || fail "future override should keep us active past the start hour, got $got"

  # Same override, but now it is 22:00 (past the override) => blackout resumes; the
  # past override is auto-ignored.
  got=$(FM_STATE_OVERRIDE="$state" FM_BLACKOUT_ENABLED=1 FM_BLACKOUT_NOW_EPOCH=1704164400 \
    bash -c ". '$ROOT/bin/fm-blackout-lib.sh'; fm_in_blackout && echo blackout || echo active")
  [ "$got" = blackout ] || fail "a past override must be ignored (auto-expiry), got $got"
  pass "extend: a future override keeps us active; a past override is ignored"
}

test_extend_script() {
  local state="$TMP_ROOT/ext-cli/state" out ov
  mkdir -p "$state"
  # +2h from 07:00 ET => 09:00 ET; the override file holds a future epoch.
  out=$(FM_STATE_OVERRIDE="$state" FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_1200" \
    bash "$ROOT/bin/fm-blackout-extend.sh" +2h)
  assert_contains "$out" "supervising until" "extend +2h did not confirm an active-until time"
  ov=$(cat "$state/blackout-override")
  case "$ov" in ''|*[!0-9]*) fail "extend did not write a numeric override epoch, got '$ov'" ;; esac
  [ "$ov" -gt "$EPOCH_WINTER_1200" ] || fail "extend override should be in the future"

  # HH:MM later today.
  out=$(FM_STATE_OVERRIDE="$state" FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_1200" \
    bash "$ROOT/bin/fm-blackout-extend.sh" 21:00)
  assert_contains "$out" "21:00" "extend HH:MM did not confirm the target time"

  # A time already past today is refused (nothing to extend).
  local rc=0
  FM_STATE_OVERRIDE="$state" FM_BLACKOUT_NOW_EPOCH=1704150000 \
    bash "$ROOT/bin/fm-blackout-extend.sh" 05:00 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "extend to a past time should be refused"

  # --clear removes the override.
  FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-blackout-extend.sh" --clear >/dev/null 2>&1
  [ ! -f "$state/blackout-override" ] || fail "--clear did not remove the override file"
  pass "extend script: +Nh/HH:MM write a future override, past target refused, --clear removes it"
}

# --- WATCHER: clean blackout exit -------------------------------------------

# Run fm-watch.sh with a bounded lifetime; echo its exit code. A background killer
# guarantees the test cannot hang if the blackout exit ever regressed to looping.
run_watch_bounded() {
  local state=$1 epoch=$2 afk=${3:-} rc watch_pid killer_pid
  mkdir -p "$state"
  [ -n "$afk" ] && : > "$state/.afk"
  FM_STATE_OVERRIDE="$state" FM_BLACKOUT_ENABLED=1 FM_BLACKOUT_NOW_EPOCH="$epoch" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
  watch_pid=$!
  ( sleep 5; kill -KILL "$watch_pid" 2>/dev/null ) &
  killer_pid=$!
  wait "$watch_pid"; rc=$?
  kill "$killer_pid" 2>/dev/null || true
  wait "$killer_pid" 2>/dev/null || true
  echo "$rc"
}

test_watcher_blackout_exit() {
  local rc
  # In blackout, non-afk: the watcher stops immediately with the blackout code
  # (well under the 5s killer, so a KILL/137 would prove a hang).
  rc=$(run_watch_bounded "$TMP_ROOT/watch-bo" "$EPOCH_WINTER_0100")
  [ "$rc" = "$FM_BLACKOUT_EXIT_CODE" ] || \
    fail "watcher in blackout should exit $FM_BLACKOUT_EXIT_CODE, got $rc"
  pass "watcher: crossing into blackout exits cleanly with FM_BLACKOUT_EXIT_CODE"
}

test_watcher_afk_no_blackout_exit() {
  local rc
  # Under afk the daemon owns the watcher and applies the blackout at its
  # injection gate, so the watcher must NOT take the blackout exit; it keeps
  # running (killed by the 5s backstop => 137).
  rc=$(run_watch_bounded "$TMP_ROOT/watch-afk" "$EPOCH_WINTER_0100" afk)
  [ "$rc" != "$FM_BLACKOUT_EXIT_CODE" ] || \
    fail "watcher under afk must not take the blackout exit"
  pass "watcher: under afk the blackout exit is suppressed (daemon owns triage)"
}

# --- ARM: sleeper scheduling and singleton safety ----------------------------

# Wait up to <limit> 0.1s ticks for <file> to contain <needle>; 0 on match.
wait_for_line() {
  local file=$1 needle=$2 limit=${3:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -qF "$needle" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_arm_blackout_sleeper() {
  local state="$TMP_ROOT/arm-bo/state" out1="$TMP_ROOT/arm-bo/out1" arm1_pid out2
  mkdir -p "$state" "$TMP_ROOT/arm-bo"
  # Arm during blackout: it must NOT start an active watcher, print the blackout
  # status line, and block as a zero-token sleeper holding the singleton lock.
  FM_STATE_OVERRIDE="$state" FM_BLACKOUT_ENABLED=1 FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_0100" \
    FM_BLACKOUT_SLEEP_CHUNK=1 \
    bash "$ROOT/bin/fm-watch-arm.sh" >"$out1" 2>&1 &
  arm1_pid=$!

  wait_for_line "$out1" "blackout until 05:00 ET (resume scheduled)" || {
    kill "$arm1_pid" 2>/dev/null; fail "arm did not print the blackout status line"
  }
  assert_not_contains "$(cat "$out1")" "watcher: started" "arm wrongly started an active watcher during blackout"
  # The sleeper holds the watcher singleton lock, and the guard beacon is fresh.
  [ -e "$state/.watch.lock" ] || { kill "$arm1_pid" 2>/dev/null; fail "sleeper did not hold the watcher lock"; }
  [ -e "$state/.last-watcher-beat" ] || { kill "$arm1_pid" 2>/dev/null; fail "sleeper did not refresh the liveness beacon"; }

  # A SECOND arm during blackout must no-op (singleton-safe), not start a rival
  # sleeper: it reports the already-scheduled cycle and exits promptly.
  out2=$(FM_STATE_OVERRIDE="$state" FM_BLACKOUT_ENABLED=1 FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_0100" \
    FM_BLACKOUT_SLEEP_CHUNK=1 bash "$ROOT/bin/fm-watch-arm.sh" 2>&1)
  assert_contains "$out2" "already scheduled" "second arm during blackout did not detect the live sleeper"

  # Tearing the sleeper down releases the lock (no orphaned singleton).
  kill -TERM "$arm1_pid" 2>/dev/null || true
  wait "$arm1_pid" 2>/dev/null || true
  [ ! -e "$state/.watch.lock" ] || fail "sleeper did not release the watcher lock on teardown"
  pass "arm: blackout schedules a zero-token sleeper; singleton-safe; releases lock on teardown"
}

# --- GUARD: banner suppression vs. surviving guards --------------------------

# A repo on main with a task in flight (meta) and a STALE beacon so the
# watcher-down banner would fire in the active window.
make_guard_home() {
  local home=$1
  git init -q -b main "$home"
  git -C "$home" commit -q --allow-empty -m init
  mkdir -p "$home/state"
  fm_write_meta "$home/state/task-gg1.meta" "window=firstmate:fm-task-gg1" "kind=ship"
  # No .last-watcher-beat => beacon "never" => stale.
  printf '%s\n' "$home"
}

# Guard with the feature ENABLED (the interesting case); a variant without it
# proves the disabled default is a no-op.
run_guard() {  # <home> <epoch>
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_BLACKOUT_ENABLED=1 FM_BLACKOUT_NOW_EPOCH="$2" \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner_suppressed_in_blackout() {
  local home out
  home=$(make_guard_home "$TMP_ROOT/guard-home")

  # Active window: an absent/stale watcher with work in flight IS the alarm.
  out=$(run_guard "$home" "$EPOCH_WINTER_1200")
  assert_contains "$out" "WATCHER DOWN" "guard must alarm on a down watcher during the active window"

  # Blackout: an absent active watcher is EXPECTED, so no banner.
  out=$(run_guard "$home" "$EPOCH_WINTER_0100")
  assert_not_contains "$out" "WATCHER DOWN" "guard must NOT alarm on a down watcher during blackout"

  # Disabled (default): the blackout never suppresses anything, so the same
  # blackout-hour clock still alarms - proving the guard change is opt-in too.
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_BLACKOUT_NOW_EPOCH="$EPOCH_WINTER_0100" \
    "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$out" "WATCHER DOWN" "with the feature disabled, guard must still alarm at blackout hours"
  pass "guard: watcher-down banner fires in active window, suppressed only during an ENABLED blackout"
}

test_guard_other_guards_survive_blackout() {
  local home out
  home=$(make_guard_home "$TMP_ROOT/guard-home2")

  # Queued-wakes guard must fire in BOTH windows.
  printf '%s\t%s\t%s\t%s\t%s\n' 100 1 signal task-gg1.status "signal:task" \
    > "$home/state/.wake-queue"
  out=$(run_guard "$home" "$EPOCH_WINTER_0100")
  assert_contains "$out" "queued wakes pending" "queued-wakes guard must still fire during blackout"
  out=$(run_guard "$home" "$EPOCH_WINTER_1200")
  assert_contains "$out" "queued wakes pending" "queued-wakes guard must still fire in the active window"
  rm -f "$home/state/.wake-queue"

  # Worktree-tangle guard must fire in BOTH windows.
  git -C "$home" checkout -q -B fm/tangle-hh2
  out=$(run_guard "$home" "$EPOCH_WINTER_0100")
  assert_contains "$out" "WORKTREE TANGLE" "tangle guard must still fire during blackout"
  out=$(run_guard "$home" "$EPOCH_WINTER_1200")
  assert_contains "$out" "WORKTREE TANGLE" "tangle guard must still fire in the active window"
  pass "guard: queued-wakes and worktree-tangle guards work in both windows"
}

# --- DAEMON: injection deferred during blackout ------------------------------

# Source the daemon's functions (its main is guarded behind BASH_SOURCE) in a
# fresh bash and drive inject_msg directly. The blackout gate sits right after the
# afk presence gate and before any tmux call, so we assert via the daemon LOG
# which path inject_msg took.
run_daemon_inject() {  # <state> <epoch> <log>
  local state=$1 epoch=$2 log=$3
  FM_HOME="$TMP_ROOT/daemon" FM_STATE_OVERRIDE="$state" LOG="$log" \
    FM_BLACKOUT_ENABLED=1 FM_BLACKOUT_NOW_EPOCH="$epoch" ROOT="$ROOT" \
    bash -c '. "$ROOT/bin/fm-supervise-daemon.sh"; inject_msg "escalation digest" "$1"' _ "$state"
}

test_daemon_defers_injection_in_blackout() {
  local state="$TMP_ROOT/daemon/state" log="$TMP_ROOT/daemon/log"
  mkdir -p "$state"
  : > "$state/.afk"          # afk active, so the presence gate passes

  # In blackout: inject must be deferred with the blackout reason, before tmux.
  : > "$log"
  run_daemon_inject "$state" "$EPOCH_WINTER_0100" "$log" || true
  assert_grep "inject deferred: overnight blackout" "$log" \
    "daemon must defer injection during blackout"

  # In the active window: the blackout reason must NOT appear (it proceeds past the
  # gate and defers later for a benign reason like a missing pane instead).
  : > "$log"
  run_daemon_inject "$state" "$EPOCH_WINTER_1200" "$log" || true
  assert_no_grep "inject deferred: overnight blackout" "$log" \
    "daemon must NOT cite the blackout reason during the active window"
  pass "daemon: away-mode injection is deferred during blackout, allowed in the active window"
}

test_predicate_boundaries
test_predicate_dst
test_predicate_configurable
test_predicate_broken_clock
test_off_by_default
test_config_file_enable
test_extend_override_predicate
test_extend_script
test_watcher_blackout_exit
test_watcher_afk_no_blackout_exit
test_arm_blackout_sleeper
test_guard_banner_suppressed_in_blackout
test_guard_other_guards_survive_blackout
test_daemon_defers_injection_in_blackout
