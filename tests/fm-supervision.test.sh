#!/usr/bin/env bash
# tests/fm-supervision.test.sh - the operator's off switch for a home's whole
# background supervision loop (bin/fm-supervision.sh, docs/turnend-guard.md
# "Supervision switched off"): the switch itself, the supervision need it
# zeroes, the real watcher it stops, the arm and checkpoint that start no cycle
# while it is off, the away and quiet entries and the daemon it refuses, and the
# away or quiet daemon it stops. The real Claude Stop hook, supervision host,
# and watcher are covered in tests/fm-supervision-host-hook.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SWITCH="$ROOT/bin/fm-supervision.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
START="$ROOT/bin/fm-afk-start.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-switch)
# The daemon paths refuse on Pi and on a home that runs the supervision host, so
# pin a Claude primary on a home that opted out of the host.
unset PI_CODING_AGENT FM_PI_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS
export CLAUDECODE=1 FM_TEST_HARNESS=claude FM_TEST_SEAM=1

make_home() {  # <name>
  local home
  home=$(make_case "$1")
  mkdir -p "$home/config"
  : > "$home/config/supervision-host-off"
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$home/state/demo.meta"
  printf '%s\n' "$home"
}

switch() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$SWITCH" "$@"
}

need_verdict() {  # <home>
  bash -c '. "$1"; fm_supervision_status "$2"; printf "%s %s" "$FM_SUP_NEEDED" "$FM_SUP_OFF"' _ \
    "$ROOT/bin/fm-supervision-lib.sh" "$1/state"
}

watcher_pid() {  # <home>
  cat "$1/state/.watch.lock/pid" 2>/dev/null
}

watcher_live() {  # <home>
  local pid
  pid=$(watcher_pid "$1") || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# A real watcher holding this home's singleton, quiet until it is stopped.
WATCHER_PID=
start_real_watcher() {  # <home>
  local home=$1 i=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_POLL=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$home/watch.out" 2> "$home/watch.err" &
  WATCHER_PID=$!
  while [ "$i" -lt 100 ]; do
    [ "$(watcher_pid "$home")" = "$WATCHER_PID" ] && [ -e "$home/state/.last-watcher-beat" ] \
      && [ -s "$home/state/.watch.lock/pid-identity" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "fixture: the watcher never took this home's lock: $(cat "$home/watch.err")"
}

# A fake away or quiet daemon holding the home's singleton lock under its
# recorded identity; its TERM handler takes <term-seconds> to finish, the way a
# real daemon's flush and watcher shutdown can.
start_fake_daemon() {  # <home> <term-seconds>
  local home=$1 pid lock="$1/state/.supervise-daemon.lock"
  bash -c 'trap "sleep $1; exit 0" TERM; while :; do sleep 0.2; done' _ "$2" >/dev/null 2>&1 &
  pid=$!
  mkdir -p "$lock"
  printf '%s' "$pid" > "$lock/pid"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$pid" > "$lock/pid-identity" )
  printf 'none\t-\tnative\n' > "$home/state/.afk-daemon-terminal"
  printf '%s\n' "$pid"
}

test_off_on_status_and_usage() {
  local home out rc
  home=$(make_home basics)
  out=$(switch "$home" status) || fail "status failed on a fresh home"
  assert_contains "$out" "supervision: on" "a fresh home must read on"
  out=$(switch "$home" off --reason 'stop the loop') || fail "off failed: $out"
  assert_contains "$out" "supervision: off" "off must report the new state"
  assert_present "$home/state/.supervision-off"
  assert_grep 'reason=stop the loop' "$home/state/.supervision-off" "off must record the reason"
  cp "$home/state/.supervision-off" "$TMP_ROOT/first-marker"
  sleep 1
  switch "$home" off --reason 'another reason' >/dev/null || fail "a second off failed"
  cmp -s "$home/state/.supervision-off" "$TMP_ROOT/first-marker" \
    || fail "a second off must keep the original time and reason"
  out=$(switch "$home" status)
  assert_contains "$out" "supervision: off since " "status must report off with its time"
  assert_contains "$out" "reason: stop the loop" "status must report the recorded reason"
  assert_contains "$out" "watcher: not running" "status must report the watcher"
  out=$(switch "$home" on) || fail "on failed"
  assert_contains "$out" "supervision: on" "on must report the new state"
  assert_absent "$home/state/.supervision-off"
  out=$(switch "$home" on) || fail "a second on failed"
  assert_contains "$out" "it was not switched off" "on must say when nothing was off"
  rc=0
  switch "$home" sideways >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown subcommand must be a usage error"
  rc=0
  switch "$home" off --reason >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "--reason without a value must be a usage error"
  out=$(switch "$home" --help) || fail "--help failed"
  assert_contains "$out" "Exit status:" "--help must print the whole header"
  pass "switch: off records time and reason once, status reports it, on clears it, bad input is a usage error"
}

test_off_zeroes_supervision_need() {
  local home
  home=$(make_home need)
  assert_equals "true false" "$(need_verdict "$home")" "fixture: in-flight work must need supervision while on"
  switch "$home" off >/dev/null || fail "off failed"
  assert_equals "false true" "$(need_verdict "$home")" "switched off, in-flight work must not need supervision"
  switch "$home" on >/dev/null || fail "on failed"
  assert_equals "true false" "$(need_verdict "$home")" "switched back on, the need must return"
  pass "switch: off zeroes the supervision need every guard and arm owner reads, and on restores it"
}

test_off_stops_the_running_watcher() {
  local home out pid
  home=$(make_home stop-watcher)
  start_real_watcher "$home"
  pid=$WATCHER_PID
  out=$(switch "$home" status)
  assert_contains "$out" "watcher: running" "fixture: status must see the live watcher"
  out=$(switch "$home" off 2>&1) || fail "off failed with a live watcher: $out"
  wait "$pid" 2>/dev/null || true
  kill -0 "$pid" 2>/dev/null && fail "off left the watcher running"
  out=$(switch "$home" status)
  assert_contains "$out" "watcher: not running" "status after off must report no watcher"
  pass "switch: off stops this home's running watcher cycle"
}

test_arm_and_checkpoint_start_nothing_while_off() {
  local home out rc mode pid
  home=$(make_home arm-refuses)
  switch "$home" off >/dev/null || fail "off failed"
  for mode in '' --restart; do
    rc=0
    # shellcheck disable=SC2086 # the empty mode is deliberately no argument
    out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" "$WATCH_ARM" $mode 2>&1) || rc=$?
    expect_code 0 "$rc" "fm-watch-arm.sh ${mode:-(plain)} must exit cleanly while off: $out"
    assert_contains "$out" "watcher: off - supervision is switched off for this home" \
      "fm-watch-arm.sh ${mode:-(plain)} must say why it started nothing"
    watcher_live "$home" && fail "fm-watch-arm.sh ${mode:-(plain)} started a watcher while off"
  done
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$CHECKPOINT" --seconds 5 2>&1) || rc=$?
  expect_code 0 "$rc" "the foreground checkpoint must exit cleanly while off: $out"
  assert_contains "$out" "checkpoint: supervision is switched off for this home" \
    "the checkpoint must say why it ran nothing"
  watcher_live "$home" && fail "the checkpoint started a watcher while off"

  # A watcher a racing owner started before the marker landed is still stopped
  # by --restart, and nothing replaces it.
  start_real_watcher "$home"
  pid=$WATCHER_PID
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$WATCH_ARM" --restart 2>&1) || fail "--restart failed while off: $out"
  wait "$pid" 2>/dev/null || true
  kill -0 "$pid" 2>/dev/null && fail "--restart while off left the old watcher running"
  watcher_live "$home" && fail "--restart while off started a new watcher"
  pass "switch: the arm, its restart, and the foreground checkpoint start no cycle while off"
}

test_off_refuses_away_and_quiet_entry_and_the_daemon() {
  local home rc out cmd
  home=$(make_home refuse)
  switch "$home" off >/dev/null || fail "off failed"
  for cmd in enter start start-native; do
    rc=0
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      FM_AFK_MODE=quiet "$LAUNCH" "$cmd" 2>&1) || rc=$?
    expect_code 1 "$rc" "fm-afk-launch.sh $cmd must refuse while switched off"
    assert_contains "$out" "switched off" "fm-afk-launch.sh $cmd must say why it refused"
  done
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$START" 2>&1) || rc=$?
  expect_code 1 "$rc" "fm-afk-start.sh must refuse while switched off"
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$DAEMON" 2>&1) || rc=$?
  expect_code 0 "$rc" "the daemon must exit cleanly without starting while off: $out"
  assert_contains "$out" "the daemon does not start" "the daemon must say why it did not start"
  assert_absent "$home/state/.afk"
  assert_absent "$home/state/.afk-contract"
  assert_absent "$home/state/.supervise-daemon.lock"
  watcher_live "$home" && fail "a refused entry started a watcher"
  pass "switch: away and quiet entry, the daemon entry, and the daemon refuse and write nothing while off"
}

# A quiet daemon can take about 12 seconds to finish its shutdown, past one
# stop's 10-second wait. One off must be enough.
test_off_ends_quiet_mode_whose_daemon_stops_slowly() {
  local home pid out rc=0
  home=$(make_home slow-daemon)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AFK_MODE=quiet "$CONTRACT" enter \
    --words 'keep routine wakes off my main' >/dev/null 2>&1 || fail "fixture: could not record quiet mode"
  printf 'quiet\n%s\n' "$(date +%s)" > "$home/state/.afk"
  pid=$(start_fake_daemon "$home" 12)
  out=$(switch "$home" status)
  assert_contains "$out" "away/quiet daemon: running" "fixture: status must see the daemon"
  out=$(switch "$home" off 2>&1) || rc=$?
  expect_code 0 "$rc" "one off must end quiet mode even when the daemon takes 12 seconds to stop: $out"
  kill -0 "$pid" 2>/dev/null && fail "the daemon is still running after off"
  assert_absent "$home/state/.afk"
  assert_absent "$home/state/.afk-contract"
  assert_present "$home/state/.supervision-off"
  pass "switch: one off ends quiet mode whose daemon outlasts a single stop's wait"
}

test_off_reports_a_daemon_that_never_stops() {
  local home pid out rc=0
  home=$(make_home stuck-daemon)
  printf 'quiet\n%s\n' "$(date +%s)" > "$home/state/.afk"
  pid=$(start_fake_daemon "$home" 600)
  out=$(switch "$home" off 2>&1) || rc=$?
  expect_code 1 "$rc" "off must fail when the daemon never stops"
  assert_contains "$out" "run off again" "off must say how to retry"
  assert_present "$home/state/.supervision-off"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "switch: a daemon that never stops fails off with a retry hint and keeps the marker"
}

fm_test_run \
  test_off_on_status_and_usage \
  test_off_zeroes_supervision_need \
  test_off_stops_the_running_watcher \
  test_arm_and_checkpoint_start_nothing_while_off \
  test_off_refuses_away_and_quiet_entry_and_the_daemon \
  test_off_ends_quiet_mode_whose_daemon_stops_slowly \
  test_off_reports_a_daemon_that_never_stops
