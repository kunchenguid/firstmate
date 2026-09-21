#!/usr/bin/env bash
# tests/fm-watcher-guard-race.test.sh - HHE-1805: atomic watch-lock publication
# versus generation-pinned guard reads. The turn-end guard fired false TURN
# WOULD END BLIND alarms while the watcher was live and fresh, because the
# lock symlink was published with only the pid file before fm-home,
# watcher-path, and pid-identity were written, and guard readers traversed the
# flipping symlink once per file. These cases cycle the real lock primitive
# under concurrent guard checks: staged publication must never show a partial
# generation and must never fail a health check, while a genuinely dead watcher
# must still fail with a named reason.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-guard-race)

# observe_publication <state> <flag> <result> <expected-pid> <expected-home>.
# Spins until <flag> disappears, sampling the published lock on every pass. A
# sample counts only when one stable owner generation is observed end to end:
# the symlink target is resolved once and must still match with byte-identical
# files after the read, so release-time deletion never counts as a partial
# generation. A stable sample is partial when any owner file is missing or
# names the wrong generation. Writes "samples=N partials=M torn=T".
observe_publication() {
  local state=$1 flag=$2 result=$3 expected_pid=$4 expected_home=$5
  local lock="$state/.watch.lock" link owner samples=0 partials=0 torn=0
  local pid home path identity link_after pid_after home_after path_after identity_after
  while [ -e "$flag" ]; do
    link=$(readlink "$lock" 2>/dev/null || true)
    [ -n "$link" ] || continue
    case "$link" in
      /*) owner=$link ;;
      *) owner="$state/$link" ;;
    esac
    pid=$(cat "$owner/pid" 2>/dev/null || true)
    home=$(cat "$owner/fm-home" 2>/dev/null || true)
    path=$(cat "$owner/watcher-path" 2>/dev/null || true)
    identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
    link_after=$(readlink "$lock" 2>/dev/null || true)
    if [ "$link_after" != "$link" ]; then
      torn=$((torn + 1))
      continue
    fi
    pid_after=$(cat "$owner/pid" 2>/dev/null || true)
    home_after=$(cat "$owner/fm-home" 2>/dev/null || true)
    path_after=$(cat "$owner/watcher-path" 2>/dev/null || true)
    identity_after=$(cat "$owner/pid-identity" 2>/dev/null || true)
    if [ "$pid_after" != "$pid" ] || [ "$home_after" != "$home" ] \
      || [ "$path_after" != "$path" ] || [ "$identity_after" != "$identity" ]; then
      torn=$((torn + 1))
      continue
    fi
    samples=$((samples + 1))
    if [ "$pid" != "$expected_pid" ] || [ "$home" != "$expected_home" ] \
      || [ "$path" != "$WATCH" ] || [ -z "$identity" ]; then
      partials=$((partials + 1))
    fi
  done
  printf 'samples=%s partials=%s torn=%s\n' "$samples" "$partials" "$torn" > "$result"
}

test_staged_publication_never_shows_partial_generation() {
  local dir state flag result out pub obs samples partials pub_pid i
  dir=$(make_case staged-publication)
  state="$dir/state"
  flag="$dir/observe"
  result="$dir/observe.result"
  out="$dir/publisher.out"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    lockdir="$2/.watch.lock"
    fm_current_pid me || exit 10
    ident=$(fm_pid_identity "$me") || exit 11
    printf "%s\n" "$me" > "$3"
    FM_LOCK_OWNER_FM_HOME=$FM_HOME
    FM_LOCK_OWNER_WATCHER_PATH=$4
    FM_LOCK_OWNER_PID_IDENTITY=$ident
    for _ in $(seq 1 150); do
      fm_lock_try_acquire "$lockdir" || exit 12
      sleep 0.005
      fm_lock_release "$lockdir"
    done
  ' _ "$LIB" "$state" "$dir/publisher.pid" "$WATCH" > "$out" 2>&1 &
  pub=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$dir/publisher.pid" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$dir/publisher.pid" ] || { kill "$pub" 2>/dev/null || true; fail "staged publisher did not start"; }
  pub_pid=$(cat "$dir/publisher.pid")
  : > "$flag"
  observe_publication "$state" "$flag" "$result" "$pub_pid" "$dir" &
  obs=$!
  wait "$pub" || fail "staged publisher failed: $(cat "$out")"
  rm -f "$flag"
  wait "$obs" || fail "publication observer failed"
  out=$(cat "$result")
  samples=${out#samples=}; samples=${samples%% *}
  partials=${out#*partials=}; partials=${partials%% *}
  [ "$samples" -ge 10 ] || fail "observer sampled nothing under staged cycling (got '$out')"
  [ "$partials" -eq 0 ] || fail "staged publication showed $partials partial generations in $samples samples"
  pass "staged publication shows zero partial generations in $samples samples"
}

test_legacy_staggered_publication_is_observable() {
  local dir state flag result out pub obs samples partials pub_pid i
  dir=$(make_case legacy-publication)
  state="$dir/state"
  flag="$dir/observe"
  result="$dir/observe.result"
  out="$dir/publisher.out"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    lockdir="$2/.watch.lock"
    fm_current_pid me || exit 10
    ident=$(fm_pid_identity "$me") || exit 11
    printf "%s\n" "$me" > "$3"
    for _ in $(seq 1 40); do
      fm_lock_try_acquire "$lockdir" || exit 12
      sleep 0.05
      printf "%s\n" "$FM_HOME" > "$lockdir/fm-home"
      sleep 0.05
      printf "%s\n" "$4" > "$lockdir/watcher-path"
      sleep 0.05
      printf "%s\n" "$ident" > "$lockdir/pid-identity"
      sleep 0.01
      fm_lock_release "$lockdir"
    done
  ' _ "$LIB" "$state" "$dir/publisher.pid" "$WATCH" > "$out" 2>&1 &
  pub=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$dir/publisher.pid" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$dir/publisher.pid" ] || { kill "$pub" 2>/dev/null || true; fail "legacy publisher did not start"; }
  pub_pid=$(cat "$dir/publisher.pid")
  : > "$flag"
  observe_publication "$state" "$flag" "$result" "$pub_pid" "$dir" &
  obs=$!
  wait "$pub" || fail "legacy publisher failed: $(cat "$out")"
  rm -f "$flag"
  wait "$obs" || fail "publication observer failed"
  out=$(cat "$result")
  samples=${out#samples=}; samples=${samples%% *}
  partials=${out#*partials=}; partials=${partials%% *}
  [ "$samples" -ge 1 ] || fail "observer sampled nothing under legacy cycling"
  [ "$partials" -ge 1 ] || fail "observer missed the legacy staggered window entirely ($samples samples, harness is blind)"
  pass "legacy staggered publication is observable ($partials partials in $samples samples)"
}

test_rapid_cycling_yields_no_false_blind() {
  local dir state out pub reader fails reasons
  dir=$(make_case rapid-cycling)
  state="$dir/state"
  out="$dir/cycling.out"
  touch "$state/.last-watcher-beat"
  # Production-shaped arm cycling: each generation is HELD (a live watcher
  # supervising) and the release-plus-republish gap is milliseconds. A guard
  # evaluation must never decide on mixed-generation state and must ride out
  # the gap inside its default bounded retries.
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    lockdir="$2/.watch.lock"
    fm_current_pid me || exit 10
    ident=$(fm_pid_identity "$me") || exit 11
    FM_LOCK_OWNER_FM_HOME=$FM_HOME
    FM_LOCK_OWNER_WATCHER_PATH=$3
    FM_LOCK_OWNER_PID_IDENTITY=$ident
    for _ in $(seq 1 25); do
      fm_lock_try_acquire "$lockdir" || exit 12
      sleep 0.2
      fm_lock_release "$lockdir"
    done
    fm_lock_try_acquire "$lockdir" || exit 12
    for _ in $(seq 1 150); do
      [ -e "$4" ] && break
      sleep 0.2
    done
    fm_lock_release "$lockdir"
    touch "$5"
  ' _ "$LIB" "$state" "$WATCH" "$dir/reader.done" "$dir/cycling.done" > "$out" 2>&1 &
  pub=$!
  reader=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    fails=0
    evals=0
    reasons=
    for _ in $(seq 1 50); do
      if [ -e "$2/.watch.lock" ] || [ -L "$2/.watch.lock" ]; then
        break
      fi
      sleep 0.1
    done
    for _ in $(seq 1 400); do
      if [ -e "$5" ] || ! kill -0 "$6" 2>/dev/null; then
        break
      fi
      evals=$((evals + 1))
      if ! fm_watcher_healthy "$2" "$3" 300 "$4"; then
        fails=$((fails + 1))
        reasons="$reasons[$FM_WATCHER_HEALTH_REASON]"
      fi
    done
    touch "$7"
    printf "fails=%s evals=%s reasons=%s\n" "$fails" "$evals" "$reasons"
  ' _ "$LIB" "$state" "$WATCH" "$dir" "$dir/cycling.done" "$pub" "$dir/reader.done")
  wait "$pub" || fail "cycling publisher failed: $(cat "$out")"
  fails=${reader#fails=}; fails=${fails%% *}
  evals=${reader#*evals=}; evals=${evals%% *}
  reasons=${reader#*reasons=}
  [ "$evals" -ge 50 ] || fail "reader overlapped too little cycling to prove anything ($evals evaluations)"
  [ "$fails" -eq 0 ] || fail "$fails false-BLIND guard failures under rapid cycling (reasons:$reasons)"
  pass "rapid arm cycling yields zero false-BLINDs in $evals guard evaluations"
}

test_health_reason_matrix() {
  local dir state live identity reason
  dir=$(make_case reason-matrix)
  state="$dir/state"
  touch "$state/.last-watcher-beat"
  sleep 300 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || { kill "$live" 2>/dev/null || true; fail "could not identify a live pid"; }

  check_reason() {  # <label> <expected-reason> <expected-rc>
    local label=$1 expected_reason=$2 expected_rc=$3 got_reason got_rc=0
    got_reason=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
      . "$1"
      if fm_watcher_healthy "$2" "$3" 300 "$4"; then rc=0; else rc=1; fi
      printf "%s:%s" "$rc" "$FM_WATCHER_HEALTH_REASON"
    ' _ "$LIB" "$state" "$WATCH" "$dir") || fail "$label: health probe crashed"
    got_rc=${got_reason%%:*}
    got_reason=${got_reason#*:}
    [ "$got_rc" = "$expected_rc" ] || fail "$label: expected rc $expected_rc, got $got_rc"
    [ "$got_reason" = "$expected_reason" ] || fail "$label: expected reason $expected_reason, got $got_reason"
  }

  mkdir "$state/.watch.lock"
  printf '%s\n' "$(dead_pid)" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
  check_reason dead-pid pid-dead 1

  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch -t 200001010000 "$state/.last-watcher-beat"
  check_reason stale-beacon beacon-stale 1
  touch "$state/.last-watcher-beat"

  printf '%s\n' "/no/such/home" > "$state/.watch.lock/fm-home"
  check_reason wrong-home home-mismatch 1
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"

  printf '%s\n' "/no/such/watcher.sh" > "$state/.watch.lock/watcher-path"
  check_reason wrong-path path-mismatch 1
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"

  rm -f "$state/.watch.lock/pid-identity"
  check_reason missing-identity identity-missing 1
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  check_reason wrong-identity identity-mismatch 1
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"

  reason=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    if fm_watcher_healthy "$2" "$3" 300 "$4"; then rc=0; else rc=1; fi
    printf "%s:%s:%s" "$rc" "$FM_WATCHER_HEALTH_REASON" "$FM_WATCHER_HEALTHY_PID"
  ' _ "$LIB" "$state" "$WATCH" "$dir") || reason="crashed"
  [ "$reason" = "0:ok:$live" ] || fail "live complete lock did not verify healthy (got '$reason')"

  rm -rf "$state/.watch.lock"
  check_reason absent-lock lock-absent 1

  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "dead watcher still blocks with a named predicate reason"
}

test_verdict_carries_health_detail() {
  local dir state detail
  dir=$(make_case verdict-detail)
  state="$dir/state"
  touch -t 200001010000 "$state/.last-watcher-beat"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$(dead_pid)" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
  detail=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_SUPERVISION_MODEL=persistent bash -c '
    . "$1"
    fm_watcher_supervision_verdict "$2" "$3" 300 "$4" "$5"
    printf "%s:%s:%s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON" "$FM_WATCHER_VERDICT_DETAIL"
  ' _ "$LIB" "$state" "$WATCH" "$dir" "$dir") || fail "verdict probe crashed"
  [ "$detail" = "false:stale-beacon:pid-dead" ] || fail "verdict detail wrong (got '$detail')"
  pass "supervision verdict carries the failed health predicate"
}

test_staged_acquire_publishes_complete_lock() {
  local dir state ready done_flag holder lock_pid i
  dir=$(make_case staged-acquire)
  state="$dir/state"
  ready="$dir/holder.ready"
  done_flag="$dir/holder.done"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    lockdir="$2/.watch.lock"
    fm_current_pid me || exit 10
    ident=$(fm_pid_identity "$me") || exit 11
    FM_LOCK_OWNER_FM_HOME=$FM_HOME
    FM_LOCK_OWNER_WATCHER_PATH=$3
    FM_LOCK_OWNER_PID_IDENTITY=$ident
    fm_lock_try_acquire "$lockdir" || exit 12
    touch "$4"
    while [ ! -e "$5" ]; do sleep 0.05; done
    fm_lock_release "$lockdir"
  ' _ "$LIB" "$state" "$WATCH" "$ready" "$done_flag" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null || true; fail "staged holder did not acquire"; }
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || fail "published lock has no pid file"
  [ "$(cat "$state/.watch.lock/fm-home" 2>/dev/null || true)" = "$dir" ] || fail "published lock has no staged fm-home"
  [ "$(cat "$state/.watch.lock/watcher-path" 2>/dev/null || true)" = "$WATCH" ] || fail "published lock has no staged watcher-path"
  [ -s "$state/.watch.lock/pid-identity" ] || fail "published lock has no staged pid-identity"
  : > "$done_flag"
  wait "$holder" || fail "staged holder failed to release"
  pass "staged acquire publishes a complete lock generation"
}

test_staged_publication_never_shows_partial_generation
test_legacy_staggered_publication_is_observable
test_rapid_cycling_yields_no_false_blind
test_health_reason_matrix
test_verdict_carries_health_detail
test_staged_acquire_publishes_complete_lock
