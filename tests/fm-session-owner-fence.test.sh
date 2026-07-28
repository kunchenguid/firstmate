#!/usr/bin/env bash
# tests/fm-session-owner-fence.test.sh - supervision session-owner fence
# (bin/fm-session-lock-lib.sh fm_session_owner_fence, enforced by
# bin/fm-watch.sh and bin/fm-watch-arm.sh).
#
# Reproduces the cross-harness ownership bug: a watcher armed by one harness
# session survived that session's death and retained the singleton after a
# different harness acquired the home's state/.lock, absorbing wakes no live
# conversation could read. Fake harnesses are bash symlinked as "claude" and
# "codex" (the established fm-claude-stop-autoarm fixture pattern), so the
# ancestry walk and fm_harness_pid_alive see real harness-named processes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
SESSION_LIB="$ROOT/bin/fm-session-lock-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-owner-fence)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness")
ln -s /bin/bash "$FAKEBIN/claude"
ln -s /bin/bash "$FAKEBIN/codex"
FAKE_CLAUDE="$FAKEBIN/claude"
FAKE_CODEX="$FAKEBIN/codex"

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

# Start a live fake harness that idles until <stop-file> appears. Compound
# command on purpose: a single command would be exec-optimized away and the
# process would stop looking like a harness. Echoes nothing; caller reads the
# harness pid from <pid-file>.
start_idle_harness() {  # <fake-harness-bin> <pid-file> <stop-file>
  # shellcheck disable=SC2016  # the body must expand inside the fake harness's shell
  "$1" -c '
    printf "%s\n" "$$" > "$1"
    while [ ! -f "$2" ]; do sleep 0.1; done
  ' _ "$2" "$3" &
}

wait_for_file() {  # <path> [limit]
  local i=0 limit=${2:-80}
  while [ "$i" -lt "$limit" ] && [ ! -s "$1" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$1" ]
}

write_watcher_lock() {
  local state=$1 home=$2 pid=$3 identity
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$WAKE_LIB" "$pid") \
    || fail "could not resolve watcher identity for pid $pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
}

start_session_claim_holder() {
  local state=$1 ready=$2 stop=$3
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2/.lock.acquire"
    printf "%s\n" ready > "$3"
    while [ ! -e "$4" ]; do sleep 0.1; done
    fm_lock_release "$2/.lock.acquire"
  ' _ "$WAKE_LIB" "$state" "$ready" "$stop" &
}

# Start a watcher as a child of a live fake claude that first writes its own
# pid into state/.lock (the session-lock owner) and then idles until
# <dir>/a-stop appears. Populates <dir>/a.pid (harness) and <dir>/a-watch.pid
# (watcher); watcher stdout goes to <dir>/a.out.
start_owned_watcher() {  # <dir> <state>
  local dir=$1 state=$2
  # shellcheck disable=SC2016  # the body must expand inside the fake harness's shell
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$1"
      printf "%s\n" "$$" > "$2"
      "$3" > "$4" 2>&1 &
      printf "%s\n" "$!" > "$5"
      while [ ! -f "$6" ]; do sleep 0.1; done
    ' _ "$dir/a.pid" "$state/.lock" "$WATCH" "$dir/a.out" "$dir/a-watch.pid" "$dir/a-stop" &
  wait_for_file "$dir/a-watch.pid" || fail "owned watcher fixture did not start"
  local i=0 wpid
  wpid=$(cat "$dir/a-watch.pid")
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "owned watcher did not publish its singleton lock"
}

test_arm_refuses_foreign_live_owner() {
  local dir state out rc foreign
  dir=$(make_case fence-arm-refusal)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  start_idle_harness "$FAKE_CLAUDE" "$dir/foreign.pid" "$dir/foreign-stop"
  wait_for_file "$dir/foreign.pid" || fail "foreign fake harness did not start"
  foreign=$(cat "$dir/foreign.pid")
  printf '%s\n' "$foreign" > "$state/.lock"
  rc=0
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" 2>&1) || rc=$?
  touch "$dir/foreign-stop"
  [ "$rc" -ne 0 ] || fail "arm exited zero under a live foreign session owner"
  assert_contains "$out" "watcher: FAILED - session-owner fence: home session lock is held by live harness pid $foreign" "arm did not print the typed fence refusal"
  assert_contains "$out" "not arming" "arm fence refusal missing its action phrase"
  [ ! -e "$state/.watch.lock" ] || fail "fenced arm still created a watcher singleton"
  pass "arm refuses to start supervision under a live foreign session owner"
}

test_watcher_refuses_foreign_live_owner_at_startup() {
  local dir state out rc foreign
  dir=$(make_case fence-watcher-startup-refusal)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  start_idle_harness "$FAKE_CLAUDE" "$dir/foreign.pid" "$dir/foreign-stop"
  wait_for_file "$dir/foreign.pid" || fail "foreign fake harness did not start"
  foreign=$(cat "$dir/foreign.pid")
  printf '%s\n' "$foreign" > "$state/.lock"
  rc=0
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" 2>&1) || rc=$?
  touch "$dir/foreign-stop"
  [ "$rc" -ne 0 ] || fail "watcher exited zero under a live foreign session owner"
  assert_contains "$out" "watcher: FAILED - session-owner fence: home session lock is held by live harness pid $foreign" "watcher did not print the typed startup fence refusal"
  assert_contains "$out" "not starting" "watcher startup refusal missing its action phrase"
  [ ! -e "$state/.watch.lock" ] || fail "fenced watcher still created a singleton"
  pass "watcher refuses startup under a live foreign session owner"
}

test_cached_owner_identity_rejects_reused_pid() {
  local dir state rc
  dir=$(make_case fence-pid-reuse)
  state="$dir/state"
  printf '%s\n' 4242 > "$state/.lock"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fake_identity=original
    fm_harness_ancestry_pid() { printf "%s\n" 4242; }
    fm_session_process_identity() { printf "%s\n" "$fake_identity"; }
    fm_harness_pid_alive() { return 0; }
    fm_session_owner_fence "$2" || exit 10
    fake_identity=reused
    if fm_session_owner_fence "$2"; then
      exit 11
    fi
    [ "$FM_SESSION_OWNER_FOREIGN_PID" = 4242 ] || exit 12
  ' _ "$SESSION_LIB" "$state" || rc=$?
  [ "$rc" -eq 0 ] || fail "memoized owner identity trusted a reused pid (status $rc)"
  pass "memoized harness ownership rejects a reused pid identity"
}

test_restart_from_non_owner_leaves_owner_watcher() {
  local dir state out rc wpid a_pid lock_pid
  dir=$(make_case fence-restart-refusal)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  start_owned_watcher "$dir" "$state"
  wpid=$(cat "$dir/a-watch.pid")
  a_pid=$(cat "$dir/a.pid")
  rc=0
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "non-owner restart exited zero"
  assert_contains "$out" 'watcher: FAILED - session-owner fence:' "non-owner restart did not print the typed fence refusal"
  is_live_non_zombie "$wpid" || fail "non-owner restart killed the owner's watcher"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$wpid" ] || fail "non-owner restart disturbed the owner's singleton (got '$lock_pid')"
  touch "$dir/a-stop"
  kill "$wpid" "$a_pid" 2>/dev/null || true
  pass "non-owner restart cannot stop the owning session's watcher"
}

test_restart_serializes_owner_check_and_termination() {
  local dir state peer claim_holder foreign arm_pid rc out dead
  dir=$(make_case fence-restart-serialization)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  dead=$(dead_pid)
  printf '%s\n' "$dead" > "$state/.lock"
  sleep 300 &
  peer=$!
  write_watcher_lock "$state" "$dir" "$peer"
  touch "$state/.last-watcher-beat"
  start_session_claim_holder "$state" "$dir/claim-ready" "$dir/claim-stop"
  claim_holder=$!
  wait_for_file "$dir/claim-ready" || fail "session claim holder did not acquire"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --restart > "$dir/restart.out" 2>&1 &
  arm_pid=$!
  sleep 0.5
  is_live_non_zombie "$peer" || fail "restart terminated the watcher while session ownership could still transfer"
  start_idle_harness "$FAKE_CODEX" "$dir/foreign.pid" "$dir/foreign-stop"
  wait_for_file "$dir/foreign.pid" || fail "foreign fake harness did not start"
  foreign=$(cat "$dir/foreign.pid")
  printf '%s\n' "$foreign" > "$state/.lock"
  touch "$dir/claim-stop"
  wait "$claim_holder" 2>/dev/null || true
  rc=0
  wait "$arm_pid" || rc=$?
  out=$(cat "$dir/restart.out")
  [ "$rc" -ne 0 ] || fail "restart crossed a session-lock handoff"
  assert_contains "$out" "not restarting" "serialized restart omitted its ownership refusal"
  is_live_non_zombie "$peer" || fail "serialized restart killed the new session's recorded watcher"
  touch "$dir/foreign-stop"
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "restart serializes ownership validation with watcher termination"
}

test_attached_successor_rechecks_owner_after_wait() {
  local dir state first arm_pid peer foreign i rc out
  dir=$(make_case fence-attached-successor)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/first.out" 2>&1 &
  first=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$first" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$first" ] || fail "first watcher did not become healthy"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$dir/arm.out" 2>&1 &
  arm_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$first" "$dir/arm.out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$first" "$dir/arm.out" || fail "arm did not attach to the first watcher"
  kill "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  i=0
  while [ "$i" -lt 80 ] && [ -e "$state/.watch.lock" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -e "$state/.watch.lock" ] || fail "first watcher did not release its singleton"
  touch -t 200001010000 "$state/.last-watcher-beat"
  sleep 300 &
  peer=$!
  write_watcher_lock "$state" "$dir" "$peer"
  start_idle_harness "$FAKE_CODEX" "$dir/foreign.pid" "$dir/foreign-stop"
  wait_for_file "$dir/foreign.pid" || fail "foreign fake harness did not start"
  foreign=$(cat "$dir/foreign.pid")
  printf '%s\n' "$foreign" > "$state/.lock"
  touch "$state/.last-watcher-beat"
  rc=0
  wait "$arm_pid" || rc=$?
  out=$(cat "$dir/arm.out")
  [ "$rc" -ne 0 ] || fail "attached arm crossed a session handoff"
  assert_contains "$out" "not attaching to successor" "attached successor wait omitted its owner recheck"
  ! grep -qF "watcher: attached pid=$peer" "$dir/arm.out" || fail "old arm reported attachment to the new owner's successor"
  touch "$dir/foreign-stop"
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "attached successor wait rechecks ownership before attachment"
}

test_owned_child_successor_rechecks_owner_after_wait() {
  local dir state peer foreign arm_pid i rc out
  dir=$(make_case fence-owned-child-successor)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  peer=$!
  write_watcher_lock "$state" "$dir" "$peer"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$dir/arm.out" 2>&1 &
  arm_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "owned child did not enter its successor wait"
  start_idle_harness "$FAKE_CODEX" "$dir/foreign.pid" "$dir/foreign-stop"
  wait_for_file "$dir/foreign.pid" || fail "foreign fake harness did not start"
  foreign=$(cat "$dir/foreign.pid")
  printf '%s\n' "$foreign" > "$state/.lock"
  touch "$state/.last-watcher-beat"
  rc=0
  wait "$arm_pid" || rc=$?
  out=$(cat "$dir/arm.out")
  [ "$rc" -ne 0 ] || fail "owned-child arm crossed a session handoff"
  assert_contains "$out" "not attaching to successor" "owned-child successor wait omitted its owner recheck"
  ! grep -qF "watcher: attached pid=$peer" "$dir/arm.out" || fail "owned-child arm reported attachment to the new owner's successor"
  touch "$dir/foreign-stop"
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "owned-child successor wait rechecks ownership before attachment"
}

test_cross_harness_takeover_stands_down_and_hands_over() {
  # The reproduced bug end to end: harness A's watcher survives A's death as an
  # orphan (dead-owner pass keeps it running - recovery unchanged), then a live
  # harness B takes the session lock. The orphan must stand down within one
  # poll, release the singleton, and a B-descended arm must then start fresh
  # supervision (the self-owned pass).
  local dir state wpid a_pid b_pid arm_pid new_pid i
  dir=$(make_case fence-cross-harness)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  start_owned_watcher "$dir" "$state"
  wpid=$(cat "$dir/a-watch.pid")
  a_pid=$(cat "$dir/a.pid")

  # Orphan the watcher: harness A exits, its session lock still names dead A.
  touch "$dir/a-stop"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$a_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$a_pid" && fail "fake harness A did not exit"
  sleep 2
  is_live_non_zombie "$wpid" || fail "orphan watcher stood down behind a DEAD owner (recovery pass broken)"

  # Harness B takes over the home.
  # shellcheck disable=SC2016  # the body must expand inside the fake harness's shell
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$FAKE_CODEX" -c '
      printf "%s\n" "$$" > "$1"
      while [ ! -f "$2" ]; do sleep 0.1; done
      "$3" > "$4" 2>&1 &
      printf "%s\n" "$!" > "$5"
      wait
    ' _ "$dir/b.pid" "$dir/b-go" "$WATCH_ARM" "$dir/b-arm.out" "$dir/b-arm.pid" &
  wait_for_file "$dir/b.pid" || fail "fake harness B did not start"
  b_pid=$(cat "$dir/b.pid")
  printf '%s\n' "$b_pid" > "$state/.lock"

  # The orphan must stand down within one poll and release the singleton.
  i=0
  while [ "$i" -lt 150 ]; do
    ! is_live_non_zombie "$wpid" && [ ! -e "$state/.watch.lock" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$wpid" || fail "orphan watcher retained supervision after a live foreign takeover"
  [ ! -e "$state/.watch.lock" ] || fail "fenced orphan watcher did not release the singleton"
  grep -qF 'session-owner fence' "$dir/a.out" || fail "orphan watcher stood down without the typed fence line: $(cat "$dir/a.out")"
  grep -qF 'standing down' "$dir/a.out" || fail "orphan watcher fence line missing its stand-down phrase"

  # The new owner's own arm now starts fresh supervision unhindered.
  touch "$dir/b-go"
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF 'watcher: started pid=' "$dir/b-arm.out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$dir/b-arm.out" || fail "new owner's arm did not start after the fenced handover: $(cat "$dir/b-arm.out" 2>/dev/null)"
  new_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$new_pid" ] || fail "handed-over singleton records no watcher pid"
  kill -0 "$new_pid" 2>/dev/null || fail "handed-over singleton does not name a live watcher"
  arm_pid=$(cat "$dir/b-arm.pid" 2>/dev/null || true)
  kill "$arm_pid" "$new_pid" "$b_pid" 2>/dev/null || true
  pass "cross-harness takeover: orphan watcher stands down within one poll and the new owner arms"
}

test_dead_owner_lock_still_arms() {
  local dir state armpid lock_pid i dead
  dir=$(make_case fence-dead-owner)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  dead=$(dead_pid)
  printf '%s\n' "$dead" > "$state/.lock"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$dir/arm.out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$dir/arm.out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$dir/arm.out" || fail "arm did not start behind a dead session-lock owner: $(cat "$dir/arm.out")"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill "$armpid" "$lock_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "a dead session-lock owner does not fence recovery arming"
}

test_afk_daemon_watcher_is_exempt() {
  local dir state wpid foreign i
  dir=$(make_case fence-afk-exempt)
  state="$dir/state"
  mark_pr_check_migration_complete "$state"
  start_idle_harness "$FAKE_CLAUDE" "$dir/foreign.pid" "$dir/foreign-stop"
  wait_for_file "$dir/foreign.pid" || fail "foreign fake harness did not start"
  foreign=$(cat "$dir/foreign.pid")
  printf '%s\n' "$foreign" > "$state/.lock"
  : > "$state/.afk"
  # The away-mode daemon's watcher is not harness-descended and the lock may
  # name the captain's live session; .afk must exempt it from the fence.
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  wpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "afk watcher did not start under a live foreign lock"
  sleep 1.5
  is_live_non_zombie "$wpid" || fail "afk watcher was fenced despite state/.afk: $(cat "$dir/watch.out")"
  touch "$dir/foreign-stop"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "away-mode supervision is exempt from the session-owner fence"
}

test_arm_refuses_foreign_live_owner
test_watcher_refuses_foreign_live_owner_at_startup
test_cached_owner_identity_rejects_reused_pid
test_restart_from_non_owner_leaves_owner_watcher
test_restart_serializes_owner_check_and_termination
test_attached_successor_rechecks_owner_after_wait
test_owned_child_successor_rechecks_owner_after_wait
test_cross_harness_takeover_stands_down_and_hands_over
test_dead_owner_lock_still_arms
test_afk_daemon_watcher_is_exempt
