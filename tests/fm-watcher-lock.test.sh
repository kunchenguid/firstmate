#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# watch-arm liveness + guard warnings. These are safety-critical concurrency
# invariants (a race bug may not reproduce through an e2e), so they stay as
# focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
DETACH_LIB="$ROOT/bin/fm-detach-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)
trap fm_test_watch_cleanup_exit EXIT

# Ceiling, in 0.1s ticks, for the poll loops below that wait for a real watcher
# process to start, claim its lock, or become a zombie. Each loop breaks as soon
# as its condition holds, so this only has to outlast the slowest host: a
# watcher's startup is real work (migration, lock acquisition, library sourcing)
# and takes many times its idle-host cost when the gate runs jobs in parallel.
WATCH_WAIT=${FM_TEST_WATCH_WAIT:-300}


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid1" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && is_live_non_zombie "$pid1" \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid1" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    && is_live_non_zombie "$pid1" \
    || fail "first watcher did not establish a live singleton"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  wait "$pid2" || fail "second watcher failed while checking the live singleton"
  grep -qF "watcher: already running pid $pid1" "$out2" || fail "second watcher did not report existing singleton"
  is_live_non_zombie "$pid1" || fail "first watcher exited while the second checked its singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "second watcher preserves an established live singleton"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -E 'heartbeat is stale|watcher exclusion could not be acquired|watcher ownership is ambiguous' "$err" >/dev/null \
    || fail "watcher did not explain the stale live lock: $(cat "$err")"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is re-arm-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line peer identity start
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'supervision protocol' "$err" >/dev/null || fail "guard banner missing protocol-owned repair guidance"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 300 &
  peer=$!
  identity=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify guard peer pid"
  start=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_start "$2"' _ "$LIB" "$peer") || fail "could not identify guard peer start"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$start" > "$state/.watch.lock/pid-start"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch.lock/pending-reply-protocol"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || {
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "guard failed"
  }
  [ ! -s "$err" ] || fail "guard warned with a fresh live watcher and no queued wakes: $(cat "$err")"
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "guard banner leads when down with pending wakes (re-arm-after-drain) and stays silent when fresh+live"
}

test_guard_requires_live_matching_watch_lock() {
  local dir state err peer identity start

  # A fresh beacon alone is not proof: the previous watcher may have exited
  # cleanly after writing a wake, leaving a fresh .last-watcher-beat behind.
  dir=$(make_case guard-fresh-no-lock)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  touch "$state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed with no lock"
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard stayed silent with fresh beacon but no watcher lock"
  grep -F 'no watcher has a confirmed live lock' "$err" >/dev/null || fail "guard did not explain the false-fresh beacon"

  # A live pid is still not proof unless the lock identifies THIS home and the
  # current watcher script. This protects sibling homes and reused pids.
  dir=$(make_case guard-live-wrong-home)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'window=test:fm-y\nkind=ship\n' > "$state/y.meta"
  sleep 300 &
  peer=$!
  identity=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir/other-home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || {
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "guard failed with mismatched lock"
  }
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard stayed silent for a lock from another home"
  grep -F 'watch lock belongs to another FM_HOME' "$err" >/dev/null || fail "guard did not explain the mismatched lock"
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true

  # Silence requires all three facts: live pid, matching identity/home/path, and
  # fresh beacon.
  dir=$(make_case guard-live-matching-home)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'window=test:fm-z\nkind=ship\n' > "$state/z.meta"
  sleep 300 &
  peer=$!
  identity=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify matching peer pid"
  start=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_start "$2"' _ "$LIB" "$peer") || fail "could not identify matching peer start"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$start" > "$state/.watch.lock/pid-start"
  touch "$state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || {
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "guard failed with matching lock"
  }
  [ ! -s "$err" ] || fail "guard warned with a live matching watcher lock and fresh beacon: $(cat "$err")"
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "guard requires a fresh beacon plus a live matching watcher lock"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_LOCK_STALE_AFTER=60 FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 5
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_LOCK_STALE_AFTER=60 FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 5
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_does_not_steal_live_lock_with_matching_pid_identity() {
  local dir state lockdir live identity out lockpid
  dir=$(make_case lock-live-matching-identity)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") || fail "could not identify live lock holder"
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  printf '%s\n' "$identity" > "$lockdir/pid-identity"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live lock with matching pid identity was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "matching live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "matching live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock with matching pid identity is not stolen"
}

test_lock_reclaims_live_lock_with_mismatched_pid_identity() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-mismatched-identity)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  printf '%s\n' "v1:stale identity for a previous process" > "$lockdir/pid-identity"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)"
    [ "$rc" -eq 0 ] && fm_lock_release "$2"
  ' _ "$LIB" "$lockdir")
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=0"*) ;;
    *) fail "live lock with mismatched pid identity was not reclaimed: $out" ;;
  esac
  [ -n "$lockpid" ] || fail "reclaimed mismatched-identity lock recorded no new pid: $out"
  [ "$lockpid" != "$live" ] || fail "mismatched-identity lock kept the reused live pid: $out"
  pass "live-held lock with mismatched pid identity is reclaimed"
}

test_lock_preserves_live_lock_with_legacy_pid_identity() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-legacy-identity)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  printf '%s\n' "legacy locale-sensitive process identity" > "$lockdir/pid-identity"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "legacy live lock was acquired instead of preserving it during migration: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "legacy live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "legacy live holder's lock was clobbered (got '$lockpid')"
  pass "live-held legacy identity remains protected during migration"
}

test_lock_reclaims_expired_legacy_pid_identity() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-expired-legacy-identity)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  printf '%s\n' "legacy locale-sensitive process identity" > "$lockdir/pid-identity"
  touch -t 200001010000 "$lockdir"
  out=$(FM_LOCK_LEGACY_IDENTITY_MAX_AGE=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)"
    [ "$rc" -eq 0 ] && fm_lock_release "$2"
  ' _ "$LIB" "$lockdir")
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=0"*) ;;
    *) fail "expired legacy lock was not reclaimed: $out" ;;
  esac
  [ -n "$lockpid" ] || fail "expired legacy lock recorded no replacement pid: $out"
  [ "$lockpid" != "$live" ] || fail "expired legacy lock kept the reused live pid: $out"
  pass "expired live-held legacy identity is reclaimed"
}

test_watcher_preserves_matching_expired_legacy_watcher_lock() {
  local dir state fakebin first_out second_out wpid second_pid i identity
  dir=$(make_case lock-migrate-expired-legacy-identity)
  state="$dir/state"
  fakebin="$dir/fakebin"
  first_out="$dir/first.out"
  second_out="$dir/second.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$first_out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && is_live_non_zombie "$wpid" \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    && is_live_non_zombie "$wpid" \
    || fail "seed watcher did not establish a live singleton"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${LC_ALL:-}" = legacy_TEST ]; then
  printf '%s\n' 'legacy locale-sensitive process identity'
else
  printf '%s\n' 'current process identity'
fi
SH
  cat > "$fakebin/locale" <<'SH'
#!/usr/bin/env bash
printf 'C\nlegacy_TEST\n'
SH
  chmod +x "$fakebin/ps" "$fakebin/locale"
  printf '%s\n' 'legacy locale-sensitive process identity' > "$state/.watch.lock/pid-identity"
  touch -t 200001010000 "$state/.watch.lock"
  PATH="$fakebin:$PATH" FM_LOCK_LEGACY_IDENTITY_MAX_AGE=0 FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$second_out" &
  second_pid=$!
  wait "$second_pid" || fail "second watcher failed while checking the legacy lock"
  identity=$(cat "$state/.watch.lock/pid-identity" 2>/dev/null || true)
  grep -qF "watcher: already running pid $wpid" "$second_out" || fail "matching expired legacy watcher lock was not preserved: $(cat "$second_out")"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "matching expired legacy watcher lock was replaced"
  case "$identity" in
    v1:*) ;;
    *) fail "matching expired legacy watcher lock was not migrated: $identity" ;;
  esac
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "matching expired legacy watcher identity is migrated before expiry recovery"
}

test_lock_without_pid_identity_keeps_existing_live_held_behavior() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-no-identity)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live lock without pid identity was acquired instead of preserving old behavior: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "identity-less live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "identity-less live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock without pid identity remains live-held"
}

test_lock_reclaims_zombie_owner() {
  local dir state lockdir reaper zombie stat i out lockpid
  dir=$(make_case lock-zombie-owner)
  state="$dir/state"
  lockdir="$state/.watch-arm.lock"
  perl -e '
    my ($lib, $lock) = @ARGV;
    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;
    if (!$pid) {
      exec("bash", "-c", q{. "$1"; fm_lock_try_acquire "$2" || exit 7}, "_", $lib, $lock);
      die "exec failed: $!\n";
    }
    sleep 30;
  ' "$LIB" "$lockdir" &
  reaper=$!
  zombie=
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    zombie=$(cat "$lockdir/pid" 2>/dev/null || true)
    [ -n "$zombie" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  stat=
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    stat=$(ps -p "$zombie" -o stat= 2>/dev/null | tr -d '[:space:]' || true)
    case "$stat" in
      Z*) break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  case "$stat" in
    Z*) ;;
    *) kill "$reaper" 2>/dev/null || true; wait "$reaper" 2>/dev/null || true; fail "lock owner did not become a zombie" ;;
  esac
  [ -s "$lockdir/pid-identity" ] || fail "new lock owner did not record process identity"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s pid=%s\n" "$rc" "$(cat "$2/pid" 2>/dev/null || true)"
    [ "$rc" -eq 0 ] && fm_lock_release "$2"
  ' _ "$LIB" "$lockdir")
  kill "$reaper" 2>/dev/null || true
  wait "$reaper" 2>/dev/null || true
  case "$out" in
    *"rc=0"*) ;;
    *) fail "zombie follower lock was treated as live-held: $out" ;;
  esac
  lockpid=${out#*pid=}
  [ -n "$lockpid" ] || fail "reclaimed zombie follower lock recorded no replacement pid"
  pass "zombie follower lock is reclaimed using its stored process identity"
}

test_lock_reclaims_legacy_zombie_owner() {
  local dir state lockdir reaper zombie stat i out lockpid
  dir=$(make_case lock-legacy-zombie-owner)
  state="$dir/state"
  lockdir="$state/.watch-arm.lock"
  perl -e '
    my ($lib, $lock) = @ARGV;
    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;
    if (!$pid) {
      exec("bash", "-c", q{. "$1"; fm_lock_try_acquire "$2" || exit 7}, "_", $lib, $lock);
      die "exec failed: $!\n";
    }
    sleep 30;
  ' "$LIB" "$lockdir" &
  reaper=$!
  zombie=
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    zombie=$(cat "$lockdir/pid" 2>/dev/null || true)
    [ -n "$zombie" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  rm -f "$lockdir/pid-identity" "$lockdir/pid-start"
  stat=
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    stat=$(ps -p "$zombie" -o stat= 2>/dev/null | tr -d '[:space:]' || true)
    case "$stat" in
      Z*) break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  case "$stat" in
    Z*) ;;
    *) kill "$reaper" 2>/dev/null || true; wait "$reaper" 2>/dev/null || true; fail "legacy lock owner did not become a zombie" ;;
  esac
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s pid=%s\n" "$rc" "$(cat "$2/pid" 2>/dev/null || true)"
    [ "$rc" -eq 0 ] && fm_lock_release "$2"
  ' _ "$LIB" "$lockdir")
  kill "$reaper" 2>/dev/null || true
  wait "$reaper" 2>/dev/null || true
  case "$out" in
    *"rc=0"*) ;;
    *) fail "legacy zombie follower lock was treated as live-held: $out" ;;
  esac
  lockpid=${out#*pid=}
  [ -n "$lockpid" ] || fail "reclaimed legacy zombie follower lock recorded no replacement pid"
  pass "legacy zombie follower lock is reclaimed without new metadata"
}

test_pid_start_fallback_uses_process_group_identity() {
  local dir fakebin first second
  dir=$(make_case pid-start-fallback)
  fakebin="$dir/fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
args="$*"
pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
  case "$args" in
  *'pgid='*'command='*)
    case "$pid" in
      987654) printf '%s\n' 'same-second-start 101 ? --fm-detach-token=first' ;;
      *) printf '%s\n' 'same-second-start 101 ? --fm-detach-token=second' ;;
    esac
    ;;
  *) printf '%s\n' 'same-second-start' ;;
esac
SH
  chmod +x "$fakebin/ps"
  first=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_start 987654' _ "$LIB") || fail "fallback start identity failed for first pid"
  second=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_start 987655' _ "$LIB") || fail "fallback start identity failed for second pid"
  [ "$first" != "$second" ] || fail "fallback process identity still collapses same-second process starts"
  pass "fallback process identity includes stable process-group and command data"
}

test_pid_start_accepts_previous_fallback_formats() {
  local dir fakebin raw ps1 ps2 ps3
  dir=$(make_case pid-start-format-migration)
  fakebin="$dir/fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *'command='*) printf '%s\n' 'same-second-start 101 ? --fm-detach-token=current' ;;
  *'pgid='*) printf '%s\n' 'same-second-start 101 ?' ;;
  *) printf '%s\n' 'same-second-start' ;;
esac
SH
  chmod +x "$fakebin/ps"
  raw='same-second-start'
  ps1='ps:same-second-start'
  ps2='ps:same-second-start 101 ?'
  ps3='ps:same-second-start 101 ? --fm-detach-token=current'
  for start in "$raw" "$ps1" "$ps2" "$ps3"; do
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_start_matches_stored 987654 "$2"' _ "$LIB" "$start" \
      || fail "fallback start token was not compatible with legacy format '$start'"
  done
  pass "fallback start identity accepts and distinguishes prior formats"
}

test_detach_kill_rejects_legacy_start_token() {
  local dir live
  dir=$(make_case detach-legacy-start)
  sleep 300 &
  live=$!
  if FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; . "$2"; fm_detach_kill "$3" "ps:legacy-start"' _ "$LIB" "$DETACH_LIB" "$live"; then
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    fail "detach cleanup accepted a legacy start token"
  fi
  is_live_non_zombie "$live" || fail "legacy cleanup token killed the live process"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "detach cleanup rejects legacy start tokens"
}

test_detach_spawn_waits_for_exec_handshake() {
  local dir fakebin output pid count
  dir=$(make_case detach-exec-handshake)
  fakebin="$dir/fakebin"
  output="$dir/detached.out"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
count=0
[ -e "${FM_FAKE_PS_COUNT:?}" ] && count=$(cat "$FM_FAKE_PS_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
case "$*" in
  *'command='*)
    if [ "$count" -lt 2 ]; then
      printf '%s\n' "sh -c launcher ${FM_EXPECTED_DETACH_PATH:?} --fm-detach-token=ready __fm_detach_launcher__"
    else
      printf '%s\n' "${FM_EXPECTED_DETACH_PATH:?} --fm-detach-token=ready"
    fi
    ;;
  *) printf '%s\n' 'S' ;;
esac
SH
  chmod +x "$fakebin/ps"
  pid=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_PS_COUNT="$dir/ps.count" \
    FM_EXPECTED_DETACH_PATH=/bin/sleep bash -c '. "$1"; . "$2"; fm_detach_spawn "$3" /bin/sleep 30' \
    _ "$LIB" "$DETACH_LIB" "$output") || fail "detached spawn did not wait for exec visibility"
  count=$(cat "$dir/ps.count" 2>/dev/null || true)
  [ "$count" -ge 2 ] || fail "detached spawn returned before the exec handshake"
  kill "$pid" 2>/dev/null || true
  pass "detached spawn waits for the target after exec"
}

test_detach_spawn_cleans_pidfile_timeout() {
  local dir fakebin output pidfile pid recorded_pid status
  dir=$(make_case detach-pidfile-timeout)
  fakebin="$dir/fakebin"
  output="$dir/detached.out"
  pidfile="$dir/launcher.pid"
  cat > "$fakebin/setsid" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${FM_FAKE_LAUNCHER_PID:?}"
exec sleep 300
SH
  chmod +x "$fakebin/setsid"
  status=0
  pid=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_LAUNCHER_PID="$pidfile" \
    bash -c '. "$1"; . "$2"; fm_detach_spawn "$3" /bin/sleep 30' \
    _ "$LIB" "$DETACH_LIB" "$output") || status=$?
  [ "$status" -ne 0 ] || fail "detached spawn succeeded without a pid file"
  recorded_pid=$(cat "$pidfile" 2>/dev/null || true)
  [ "$pid" = "$recorded_pid" ] || fail "detached spawn did not return the launcher pid"
  ! is_live_non_zombie "$pid" || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "detached spawn leaked the launcher after pid-file timeout"
  }
  pass "detached spawn cleans the launcher after pid-file timeout"
}

test_detach_spawn_cleans_exec_timeout() {
  local dir fakebin output target target_pid pid recorded_pid status
  dir=$(make_case detach-exec-timeout)
  fakebin="$dir/fakebin"
  output="$dir/detached.out"
  target="$dir/target.sh"
  target_pid="$dir/target.pid"
  cat > "$target" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${FM_TARGET_PID_FILE:?}"
exec sleep 300
SH
  chmod +x "$target"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'command='*) printf '%s\n' "sh -c launcher ${FM_EXPECTED_DETACH_PATH:?} --fm-detach-token=timeout __fm_detach_launcher__" ;;
  *) printf '%s\n' 'S' ;;
esac
SH
  chmod +x "$fakebin/ps"
  status=0
  pid=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_TARGET_PID_FILE="$target_pid" \
    FM_EXPECTED_DETACH_PATH="$target" bash -c '. "$1"; . "$2"; fm_pid_start() { return 1; }; fm_detach_spawn "$3" "$4" --fm-detach-token=timeout' \
    _ "$LIB" "$DETACH_LIB" "$output" "$target") || status=$?
  [ "$status" -ne 0 ] || fail "detached spawn succeeded without an exec transition"
  recorded_pid=$(cat "$target_pid" 2>/dev/null || true)
  [ "$pid" = "$recorded_pid" ] || fail "detached spawn did not return the target pid"
  ! is_live_non_zombie "$pid" || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "detached spawn leaked the target after exec timeout"
  }
  pass "detached spawn cleans the target after exec timeout"
}

test_arm_reclaims_legacy_follower_reused_pid() {
  local dir state fakebin out reused arm_pid watcher_pid i
  dir=$(make_case arm-legacy-follower-reuse)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  sleep 300 &
  reused=$!
  mkdir "$state/.watch-arm.lock"
  printf '%s\n' "$reused" > "$state/.watch-arm.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$out" &
  arm_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || fail "arm did not reclaim a reused legacy follower lock: $(cat "$out")"
  ! grep -qF 'watcher: follower already waiting' "$out" || fail "arm treated a reused legacy follower pid as live"
  kill "$watcher_pid" 2>/dev/null || true
  kill "$reused" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  wait "$reused" 2>/dev/null || true
  wait "$arm_pid" 2>/dev/null || true
  pass "arm reclaims a legacy follower lock whose pid was reused"
}

test_legacy_follower_scope_is_unverified() {
  local dir state fakebin lockdir live out
  dir=$(make_case arm-legacy-follower-scope)
  state="$dir/state"
  fakebin="$dir/fakebin"
  lockdir="$state/.watch-arm.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'command='*) printf '%s\n' "legacy process ${FM_EXPECTED_ARM_PATH:?}" ;;
  *'stat='*) printf '%s\n' 'S' ;;
  *) printf '%s\n' 'legacy process' ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" FM_EXPECTED_ARM_PATH="$WATCH_ARM" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2" "$3" "$4" "$3"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s unverified=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "${FM_LOCK_HELD_UNVERIFIED:-0}"
  ' _ "$LIB" "$lockdir" "$WATCH_ARM" "$dir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*"held=$live"*"unverified=1"*) ;;
    *) fail "ambiguous legacy follower lock was not held fail-closed: $out" ;;
  esac
  pass "legacy follower locks without home scope fail closed"
}

test_watcher_lock_match_rejects_zombie() {
  local dir state lockdir reaper zombie stat i identity
  dir=$(make_case watcher-zombie-health)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  perl -e '
    my ($lib, $lock) = @ARGV;
    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;
    if (!$pid) {
      exec("bash", "-c", q{. "$1"; fm_lock_try_acquire "$2" || exit 7}, "_", $lib, $lock);
      die "exec failed: $!\n";
    }
    sleep 30;
  ' "$LIB" "$lockdir" &
  reaper=$!
  zombie=
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    zombie=$(cat "$lockdir/pid" 2>/dev/null || true)
    [ -n "$zombie" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  stat=
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    stat=$(ps -p "$zombie" -o stat= 2>/dev/null | tr -d '[:space:]' || true)
    case "$stat" in
      Z*) break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  case "$stat" in
    Z*) ;;
    *) kill "$reaper" 2>/dev/null || true; wait "$reaper" 2>/dev/null || true; fail "watcher test owner did not become a zombie" ;;
  esac
  identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  printf '%s\n' "$dir" > "$lockdir/fm-home"
  printf '%s\n' "$WATCH" > "$lockdir/watcher-path"
  touch "$state/.last-watcher-beat"
  if FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_lock_matches_pid "$2" "$3" "$4" "$5"' _ "$LIB" "$lockdir" "$zombie" "$dir" "$WATCH"; then
    kill "$reaper" 2>/dev/null || true
    wait "$reaper" 2>/dev/null || true
    fail "zombie watcher lock was accepted as healthy"
  fi
  kill "$reaper" 2>/dev/null || true
  wait "$reaper" 2>/dev/null || true
  [ -n "$identity" ] || fail "zombie watcher test did not create process identity"
  pass "watcher health rejects a zombie lock owner"
}

test_watcher_lock_match_rejects_unpinned_legacy_watcher() {
  local dir state lockdir live identity
  dir=$(make_case watcher-unpinned-health)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  sleep 300 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") || fail "could not identify unpinned watcher pid"
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  printf '%s\n' "$dir" > "$lockdir/fm-home"
  printf '%s\n' "$WATCH" > "$lockdir/watcher-path"
  printf '%s\n' "$identity" > "$lockdir/pid-identity"
  if FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_lock_matches_pid "$2" "$3" "$4" "$5"' _ "$LIB" "$lockdir" "$live" "$dir" "$WATCH"; then
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    fail "unpinned legacy watcher lock was accepted as healthy"
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watcher health rejects an unpinned legacy lock"
}

test_grok_protocol_treats_existing_follower_as_live() {
  local protocol="$ROOT/docs/supervision-protocols/grok.md"
  grep -F 'watcher: follower already waiting' "$protocol" >/dev/null \
    || fail "Grok protocol omitted the existing-follower status"
  grep -F "re-arm after \`follower already waiting\`" "$protocol" >/dev/null \
    || fail "Grok protocol did not suppress re-arm after an existing follower"
  grep -F 'watcher: FAILED - follower ownership is unverified' "$protocol" >/dev/null \
    || fail "Grok protocol omitted the fail-closed legacy follower status"
  pass "Grok treats an existing follower as a live cycle"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "v1:stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm launches the fresh watcher detached and follows it, so the lock
  # names that watcher, not the arm invocation. The property is the same: the
  # stale reused-pid lock is replaced by a genuinely live watcher, which the arm
  # confirms before reporting it. Wait for that confirmation, not just for the
  # lock pid to appear (identity and beacon land a beat later).
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$out" >/dev/null || fail "restart did not report the fresh watcher it confirmed"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_arm_reclaims_reused_pid_lock_on_plain_arm() {
  local dir state fakebin armout live armpid i lock_pid
  dir=$(make_case arm-reused-pid-plain)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "v1:stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ "$lock_pid" = "$live" ]; then
    grep -E 'watcher ownership is ambiguous|PR check migration blocked' "$armout" >/dev/null \
      || fail "plain arm left the reused-pid lock without a fail-closed migration diagnostic: $(cat "$armout")"
    is_live_non_zombie "$live" || fail "plain arm killed a reused unrelated pid"
    kill "$armpid" "$live" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    pass "plain arm fails closed on a reused-pid lock before PR-check migration"
    return
  fi
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "plain arm did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$armout" >/dev/null \
    || fail "plain arm did not report the fresh watcher it confirmed: $(cat "$armout")"
  is_live_non_zombie "$live" || fail "plain arm killed a reused unrelated pid"
  kill "$armpid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "plain arm recovers from a reused-pid stale watcher lock"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt "$WATCH_WAIT" ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" "$WATCH_WAIT" || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies, the attached arm must exit 0 (cycle ended).
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" "$WATCH_WAIT"
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after seed died (status $status)"
  pass "arm attaches to a live fresh watcher and exits only when that cycle ends"
}

test_arm_migrates_live_legacy_watcher_lock() {
  local dir state fakebin out armout i wpid armpid status identity start
  dir=$(make_case arm-migrate-legacy)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  start=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_start "$2"' _ "$LIB" "$wpid") || fail "could not identify legacy watcher start"
  printf '%s\n' "$start" > "$state/.watch.lock/pid-start"
  printf '%s\n' "legacy locale-sensitive watcher identity $WATCH" > "$state/.watch.lock/pid-identity"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${LC_ALL:-}" = legacy_TEST ]; then
  printf 'legacy locale-sensitive watcher identity %s\n' "${FM_FAKE_WATCH_PATH:?}"
else
  printf 'current watcher identity %s\n' "${FM_FAKE_WATCH_PATH:?}"
fi
SH
  cat > "$fakebin/locale" <<'SH'
#!/usr/bin/env bash
printf 'C\nlegacy_TEST\n'
SH
  chmod +x "$fakebin/ps" "$fakebin/locale"
  PATH="$fakebin:$PATH" FM_FAKE_WATCH_PATH="$WATCH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  identity=$(cat "$state/.watch.lock/pid-identity" 2>/dev/null || true)
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not attach to the migrated legacy watcher: $(cat "$armout")"
  case "$identity" in
    v1:*) ;;
    *) fail "arm did not migrate the legacy watcher identity: $identity" ;;
  esac
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind the migrated legacy watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" "$WATCH_WAIT"
  status=$?
  [ "$status" -eq 0 ] || fail "arm did not exit after the migrated watcher ended (status $status)"
  pass "arm migrates and attaches to a live legacy watcher lock"
}

test_arm_rejects_unverified_legacy_watcher_lock() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-reject-legacy)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  printf '%s\n' "unrelated process with $WATCH in its command" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" "$WATCH_WAIT"
  status=$?
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "arm accepted an unverified legacy watcher"
  ! grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm attached to an unverified legacy watcher"
  grep -qF 'watcher: FAILED' "$armout" || fail "arm did not fail closed for an unverified legacy watcher: $(cat "$armout")"
  pass "arm rejects an unverified legacy watcher lock"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1; i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qF 'watcher: healthy' "$armout" || fail "arm ($row) wrongly reported healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    [ -z "$dead_pid" ] || [ "$lock_pid" != "$dead_pid" ] || fail "arm ($row) did not replace the dead-pid lock with a live watcher"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts+confirms a fresh watcher on a clean lock and self-heals a dead-pid lock (never healthy off a dead pid)"
}

test_arm_hup_stands_down_without_killing_the_watcher() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" "$WATCH_WAIT"
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  is_live_non_zombie "$lock_pid" || fail "HUP cleanup killed the detached watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
    || fail "detached watcher lock changed after arm HUP"
  [ -e "$state/.last-watcher-beat" ] || fail "detached watcher lost its liveness beacon after arm HUP"
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  pass "arm stands down on HUP while the detached watcher keeps its lock and beacon"
}

test_watcher_survives_arm_process_group_sigterm() {
  local dir state fakebin armout armpid lock_pid pgid status
  dir=$(make_case arm-process-group-reap)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # setsid gives the arm the same process-group shape as a harness-tracked task,
  # so SIGTERM to the whole arm group is the reap we must survive.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 setsid "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before process-group reap check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  pgid=$(ps -p "$armpid" -o pgid= 2>/dev/null | tr -d '[:space:]')
  [ "$pgid" = "$armpid" ] || fail "test arm is not its own process-group leader (pid=$armpid pgid=$pgid)"
  kill -TERM -- "-$pgid" 2>/dev/null || fail "could not reap the arm process group"
  wait_for_exit "$armpid" "$WATCH_WAIT"
  status=$?
  [ "$status" -ne 124 ] || fail "arm process group did not exit after SIGTERM"
  is_live_non_zombie "$lock_pid" || fail "process-group reap killed the detached watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
    || fail "detached watcher lock changed after process-group reap"
  [ -e "$state/.last-watcher-beat" ] || fail "detached watcher beacon missing after process-group reap"
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  pass "watcher survives SIGTERM of the arm's entire process group"
}

test_arm_does_not_stack_attach_waiters() {
  local dir state fakebin out first_out second_out wpid first_pid second_pid status i
  dir=$(make_case arm-single-follower)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  first_out="$dir/first-arm.out"
  second_out="$dir/second-arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$first_out" &
  first_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$first_out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$first_out" || fail "first arm did not attach to the healthy watcher"
  [ "$(cat "$state/.watch-arm.lock/fm-home" 2>/dev/null || true)" = "$dir" ] || fail "follower lock did not persist its home scope"
  [ "$(cat "$state/.watch-arm.lock/owner-path" 2>/dev/null || true)" = "$WATCH_ARM" ] || fail "follower lock did not persist its owner path"
  is_live_non_zombie "$first_pid" || fail "first arm stopped waiting on the healthy watcher"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$second_out" &
  second_pid=$!
  wait_for_exit "$second_pid" "$WATCH_WAIT"
  status=$?
  [ "$status" -eq 0 ] || fail "second arm stacked another attach waiter (status $status): $(cat "$second_out")"
  grep -qF "watcher: follower already waiting pid=$first_pid" "$second_out" || fail "second arm did not report the existing follower"
  is_live_non_zombie "$first_pid" || fail "second arm caused the existing follower to stop"

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$first_pid" "$WATCH_WAIT"
  status=$?
  [ "$status" -eq 0 ] || fail "first arm did not finish after the watcher cycle ended (status $status)"
  pass "a healthy cycle keeps one attach waiter and duplicate arms exit without stacking"
}

test_restart_handoffs_existing_follower() {
  local dir state fakebin out first_out restart_out wpid first_pid restart_pid status i lock_pid
  dir=$(make_case restart-single-follower)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  first_out="$dir/first-arm.out"
  restart_out="$dir/restart.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    "$WATCH_ARM" > "$first_out" &
  first_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$first_out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$first_out" || fail "first arm did not attach to the healthy watcher"
  is_live_non_zombie "$first_pid" || fail "first arm stopped waiting on the healthy watcher"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 \
    "$WATCH_ARM" --restart > "$restart_out" &
  restart_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$restart_pid" ] \
      && grep -qF 'watcher: started pid=' "$restart_out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$restart_out" || fail "restart did not claim the follower slot after handoff"
  is_live_non_zombie "$restart_pid" || fail "restart did not remain the sole follower"
  ! is_live_non_zombie "$first_pid" || fail "restart left two live followers after handoff"
  [ "$(cat "$state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$restart_pid" ] \
    || fail "restart did not own the follower lock after handoff: $(cat "$state/.watch-arm.lock/pid" 2>/dev/null || true)"

  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill "$lock_pid" "$wpid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  kill "$restart_pid" 2>/dev/null || true
  wait "$restart_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
  pass "restart hands off the follower slot without stacking waiters"
}

test_pid_start_distinguishes_same_second_processes() {
  local first second first_lstart second_lstart first_start second_start i
  first=
  second=
  for i in $(seq 1 40); do
    sleep 30 &
    first=$!
    sleep 0.1
    sleep 30 &
    second=$!
    first_lstart=$(LC_ALL=C ps -p "$first" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' || true)
    second_lstart=$(LC_ALL=C ps -p "$second" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' || true)
    if [ -n "$first_lstart" ] && [ "$first_lstart" = "$second_lstart" ]; then
      first_start=$(FM_STATE_OVERRIDE="$TMP_ROOT" bash -c '. "$1"; fm_pid_start "$2"' _ "$LIB" "$first") || first_start=
      second_start=$(FM_STATE_OVERRIDE="$TMP_ROOT" bash -c '. "$1"; fm_pid_start "$2"' _ "$LIB" "$second") || second_start=
      kill "$first" "$second" 2>/dev/null || true
      wait "$first" 2>/dev/null || true
      wait "$second" 2>/dev/null || true
      if [ -z "$first_start" ] || [ -z "$second_start" ]; then
        fail "process start identity was not readable"
      fi
      [ "$first_start" != "$second_start" ] || fail "same-second processes received the same start identity"
      pass "process start identity distinguishes same-second processes"
      return 0
    fi
    kill "$first" "$second" 2>/dev/null || true
    wait "$first" 2>/dev/null || true
    wait "$second" 2>/dev/null || true
  done
  fail "could not create two same-second processes for the start identity test"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod +x "$check_file"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate arm wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer beater identity start armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  start=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_start "$2"' _ "$LIB" "$peer") || fail "could not identify peer start"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$start" > "$state/.watch.lock/pid-start"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch.lock/pending-reply-protocol"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  (
    sleep 1
    touch "$state/.last-watcher-beat"
  ) &
  beater=$!
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=4 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$beater" 2>/dev/null || true
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies, the attached arm must exit 0 (same as detached attach).
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$WATCH_WAIT"
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after peer died (status $status): $(cat "$armout")"
  pass "arm attaches to a peer watcher after child stands down and exits when peer dies"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" "$WATCH_WAIT"
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" >/dev/null || fail "arm did not print the FAILED line"
  ! grep -qF 'watcher: healthy' "$armout" || fail "arm reported healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_singleton_start
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_does_not_steal_live_lock_with_matching_pid_identity
test_lock_reclaims_live_lock_with_mismatched_pid_identity
test_lock_preserves_live_lock_with_legacy_pid_identity
test_lock_reclaims_expired_legacy_pid_identity
test_watcher_preserves_matching_expired_legacy_watcher_lock
test_lock_without_pid_identity_keeps_existing_live_held_behavior
test_lock_reclaims_zombie_owner
test_lock_reclaims_legacy_zombie_owner
test_pid_start_fallback_uses_process_group_identity
test_pid_start_accepts_previous_fallback_formats
test_detach_kill_rejects_legacy_start_token
test_detach_spawn_waits_for_exec_handshake
test_detach_spawn_cleans_pidfile_timeout
test_detach_spawn_cleans_exec_timeout
test_legacy_follower_scope_is_unverified
test_watcher_lock_match_rejects_zombie
test_watcher_lock_match_rejects_unpinned_legacy_watcher
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_arm_reclaims_reused_pid_lock_on_plain_arm
test_watcher_self_evicts_on_lock_takeover
test_arm_attaches_and_waits_for_live_fresh_watcher
test_arm_migrates_live_legacy_watcher_lock
test_arm_rejects_unverified_legacy_watcher_lock
test_arm_starts_and_self_heals
test_arm_hup_stands_down_without_killing_the_watcher
test_watcher_survives_arm_process_group_sigterm
test_arm_does_not_stack_attach_waiters
test_restart_handoffs_existing_follower
test_pid_start_distinguishes_same_second_processes
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
