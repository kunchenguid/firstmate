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
    FM_LOCK_OWNER_FOR=$lockdir
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

# A generation flip (release plus re-publish) forced at an exact point inside
# one guard read. The reader's own file reads are intercepted: the n-th read of
# a named owner file first asks the publisher to flip the lock generation and
# waits until the new generation is published, then performs the real read. The
# guard therefore always spans a real flip at that read, and every position a
# torn read can occur at is covered without any wall-clock window.
test_generation_flip_mid_read_yields_no_false_blind() {
  local dir state out pub reader fails flips
  dir=$(make_case generation-flip)
  state="$dir/state"
  out="$dir/flip.out"
  touch "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    lockdir="$2/.watch.lock"
    fm_current_pid me || exit 10
    ident=$(fm_pid_identity "$me") || exit 11
    FM_LOCK_OWNER_FOR=$lockdir
    FM_LOCK_OWNER_FM_HOME=$FM_HOME
    FM_LOCK_OWNER_WATCHER_PATH=$3
    FM_LOCK_OWNER_PID_IDENTITY=$ident
    fm_lock_try_acquire "$lockdir" || exit 12
    printf "%s\n" "$me" > "$4"
    while [ ! -e "$5" ]; do
      if [ -e "$6" ]; then
        rm -f "$6"
        fm_lock_release "$lockdir"
        fm_lock_try_acquire "$lockdir" || exit 13
        printf "flip\n" >> "$7"
        : > "$8"
      fi
      sleep 0.01
    done
    fm_lock_release "$lockdir"
  ' _ "$LIB" "$state" "$WATCH" "$dir/publisher.pid" "$dir/reader.done" \
    "$dir/flip.request" "$dir/flips" "$dir/flip.done" > "$out" 2>&1 &
  pub=$!
  reader=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    dir=$2 state=$3 watch=$4
    i=0
    while [ "$i" -lt 100 ] && [ ! -s "$dir/publisher.pid" ]; do sleep 0.1; i=$((i + 1)); done
    [ -s "$dir/publisher.pid" ] || { printf "publisher never published\n"; exit 1; }
    pub_pid=$(cat "$dir/publisher.pid")
    cat() {
      local name
      case "$1" in
        "$state"/.watch.lock.owner.*/*)
          name=${1##*/}
          printf "%s\n" "$name" >> "$dir/reads.log"
          if [ -e "$dir/flip.target" ] \
            && [ "$(command cat "$dir/flip.target")" = "$name:$(grep -cx "$name" "$dir/reads.log")" ]; then
            rm -f "$dir/flip.target"
            : > "$dir/flip.request"
            while [ ! -e "$dir/flip.done" ]; do sleep 0.01; done
            rm -f "$dir/flip.done"
          fi
          ;;
      esac
      command cat "$@"
    }
    fails=0
    for target in none pid:1 fm-home:1 watcher-path:1 pid-identity:1 pid:2 fm-home:2 watcher-path:2 pid-identity:2; do
      : > "$dir/reads.log"
      rm -f "$dir/flip.target"
      [ "$target" = none ] || printf "%s\n" "$target" > "$dir/flip.target"
      if ! fm_watcher_healthy "$state" "$watch" 300 "$dir" \
        || [ "$FM_WATCHER_HEALTHY_PID" != "$pub_pid" ]; then
        fails=$((fails + 1))
        printf "flip@%s -> %s (pid %s)\n" "$target" "$FM_WATCHER_HEALTH_REASON" "$FM_WATCHER_HEALTHY_PID"
      elif [ -e "$dir/flip.target" ]; then
        fails=$((fails + 1))
        printf "flip@%s never reached that read\n" "$target"
      fi
    done
    : > "$dir/reader.done"
    printf "fails=%s\n" "$fails"
  ' _ "$LIB" "$dir" "$state" "$WATCH")
  wait "$pub" || fail "flip publisher failed: $(cat "$out")"
  flips=$(grep -c flip "$dir/flips" 2>/dev/null || echo 0)
  fails=${reader##*fails=}
  [ "$flips" -eq 8 ] || fail "expected 8 forced generation flips, publisher performed $flips"
  [ "$fails" -eq 0 ] || fail "false-BLIND guard failures across forced mid-read flips: $reader"
  pass "a generation flip at every read position inside a guard evaluation yields zero false-BLINDs"
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
    FM_LOCK_OWNER_FOR=$lockdir
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

# The claim step after symlink publication must only verify the staged pid,
# never truncate and rewrite it. The publisher's own `ln` is intercepted: right
# after the symlink goes live the pid file is made read-only and a pinned guard
# read is taken in that exact window. Any post-publication rewrite fails the
# acquisition outright, and the pinned read must see the complete generation.
test_published_pid_is_verified_not_rewritten() {
  local dir state out
  if [ "$(id -u)" = 0 ]; then
    pass "skip: the read-only pid detector needs a filesystem that can deny root's rewrite"
    return 0
  fi
  dir=$(make_case claim-verify)
  state="$dir/state"
  out=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    lockdir="$2/.watch.lock"
    fm_current_pid me || exit 10
    ident=$(fm_pid_identity "$me") || exit 11
    FM_LOCK_OWNER_FOR=$lockdir
    FM_LOCK_OWNER_FM_HOME=$FM_HOME
    FM_LOCK_OWNER_WATCHER_PATH=$3
    FM_LOCK_OWNER_PID_IDENTITY=$ident
    ln() {
      command ln "$@" || return
      chmod a-w "$2/pid"
      fm_watcher_lock_read_pinned "$STATE"
      printf "pinned rc=%s pid=%s\n" "$?" "$FM_WATCHER_PIN_PID"
    }
    if fm_lock_try_acquire "$lockdir"; then
      printf "acquired pid=%s\n" "$(command cat "$lockdir/pid")"
      chmod u+w "$lockdir/pid"
      fm_lock_release "$lockdir"
    else
      printf "acquire failed\n"
    fi
    printf "me=%s\n" "$me"
  ' _ "$LIB" "$state" "$WATCH") || fail "claim probe crashed: $out"
  local me
  me=${out##*me=}
  case "$out" in
    *"pinned rc=0 pid=$me"*) ;;
    *) fail "pinned read inside the publication window did not see the published pid: $out" ;;
  esac
  case "$out" in
    *"acquired pid=$me"*) ;;
    *) fail "acquisition rewrote the published pid file instead of verifying it: $out" ;;
  esac
  pass "the published pid is verified, never truncated and rewritten"
}

# Staging is keyed to the lock being published. On the stale-recovery path the
# same acquisition also publishes the steal lock and the recovery-marker lock;
# the publisher's `ln` is intercepted to record each owner directory at the
# moment it goes live, and only the watch lock may carry the staged files.
test_staging_applies_only_to_the_published_watch_lock() {
  local dir state log
  dir=$(make_case staging-scope)
  state="$dir/state"
  log="$dir/published.log"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$(dead_pid)" > "$state/.watch.lock/pid"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" bash -c '
    . "$1"
    lockdir="$2/.watch.lock"
    fm_current_pid me || exit 10
    ident=$(fm_pid_identity "$me") || exit 11
    FM_LOCK_OWNER_FOR=$lockdir
    FM_LOCK_OWNER_FM_HOME=$FM_HOME
    FM_LOCK_OWNER_WATCHER_PATH=$3
    FM_LOCK_OWNER_PID_IDENTITY=$ident
    log=$4
    ln() {
      command ln "$@" || return
      printf "%s: %s\n" "${3##*/}" "$(ls "$2" | sort | tr "\n" " ")" >> "$log"
    }
    fm_lock_try_acquire "$lockdir" || exit 12
    [ -n "$FM_LOCK_RECOVERED_PID" ] || exit 13
    fm_lock_release "$lockdir"
  ' _ "$LIB" "$state" "$WATCH" "$log" || fail "stale watch lock was not recovered ($?)"
  grep -qx '.watch.lock.steal: pid ' "$log" || fail "steal lock owner was not published bare: $(cat "$log")"
  grep -qx '.watcher-down.lock: pid ' "$log" || fail "recovery-marker lock owner was not published bare: $(cat "$log")"
  grep -qx '.watch.lock: fm-home pid pid-identity watcher-path ' "$log" || fail "watch lock owner was not published complete: $(cat "$log")"
  pass "staged owner files reach only the published watch lock, not the nested steal or marker locks"
}

# A post-acquire retain-evidence exit must leave the held lock and the marker
# byte-for-byte as they were. A read-only directory in place of the recovery
# marker cannot be quarantined by the arm-check, so the real watcher takes that
# exit with the lock published and held; the EXIT trap must neither release the
# lock nor touch the marker nor re-attempt the marker write that just failed.
test_retain_evidence_exit_leaves_lock_and_marker_untouched() {
  local dir state fakebin out marker pid rc i lock_pid leftover
  if [ "$(id -u)" = 0 ]; then
    pass "skip: the read-only marker needs a filesystem that can deny root's quarantine rename"
    return 0
  fi
  dir=$(make_case retain-evidence)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  marker="$state/.watcher-down"
  mkdir "$marker"
  printf 'malformed evidence\n' > "$marker/evidence"
  chmod 0500 "$marker"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    chmod 0700 "$marker"
    fail "watcher kept running instead of taking the retain-evidence exit: $(cat "$out")"
  fi
  wait "$pid"; rc=$?
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  chmod 0700 "$marker"
  [ "$rc" -eq 1 ] || fail "retain-evidence exit status was $rc: $(cat "$out")"
  grep -q 'could not be consumed safely; retaining stale lock evidence' "$out" \
    || fail "watcher did not report the retain-evidence exit: $(cat "$out")"
  ! grep -q 'could not be persisted' "$out" \
    || fail "EXIT trap re-attempted the recovery transition on a retain-evidence exit: $(cat "$out")"
  [ "$lock_pid" = "$pid" ] || fail "retain-evidence exit did not keep the lock held by pid $pid (lock pid '$lock_pid')"
  [ "$(cat "$state/.watch.lock/fm-home" 2>/dev/null)" = "$dir" ] || fail "retained lock lost its fm-home"
  [ "$(cat "$state/.watch.lock/watcher-path" 2>/dev/null)" = "$WATCH" ] || fail "retained lock lost its watcher-path"
  [ -s "$state/.watch.lock/pid-identity" ] || fail "retained lock lost its pid-identity"
  [ -d "$marker" ] && [ ! -L "$marker" ] || fail "malformed marker was replaced"
  [ "$(cat "$marker/evidence")" = "malformed evidence" ] || fail "malformed marker contents changed"
  for leftover in "$state"/.watcher-down.tmp.* "$state"/.watcher-down.invalid.*; do
    [ ! -e "$leftover" ] || fail "retain-evidence exit left marker write leftovers: $leftover"
  done
  [ ! -e "$state/.watcher-down.lock" ] && [ ! -L "$state/.watcher-down.lock" ] \
    || fail "retain-evidence exit left the marker lock held"
  pass "a retain-evidence exit leaves the held lock and the malformed marker untouched"
}

test_staged_publication_never_shows_partial_generation
test_legacy_staggered_publication_is_observable
test_generation_flip_mid_read_yields_no_false_blind
test_health_reason_matrix
test_staged_acquire_publishes_complete_lock
test_published_pid_is_verified_not_rewritten
test_staging_applies_only_to_the_published_watch_lock
test_retain_evidence_exit_leaves_lock_and_marker_untouched
