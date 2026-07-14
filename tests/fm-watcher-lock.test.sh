#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
DETACH_LIB="$ROOT/bin/fm-detach-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

# Portable mtime (macOS stat has no -c, GNU stat has no -f), for the beacon
# freshness assertions in the reap-survival case.
stat_mtime_portable() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
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
  while [ "$i" -lt 50 ]; do
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
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
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
  local dir state err first banner_line queue_line
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
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'resume supervision' "$err" >/dev/null || fail "guard banner missing the harness-aware fix command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, resume supervision' "$err" >/dev/null || fail "guard did not order supervision repair after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (re-arm-after-drain) and stays silent when fresh"
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
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
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
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
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
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
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
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm forks the fresh watcher as a tracked child and waits on it, so
  # the lock now names that child, not the arm invocation. The property is the
  # same: the stale reused-pid lock is replaced by a genuinely live watcher, which
  # the arm confirms before reporting it. Wait for that confirmation, not just for
  # the lock pid to appear (identity and beacon land a beat later).
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

test_watch_restart_reports_healthy_peer_without_attaching() {
  local dir state fakebin out peer identity armpid status i
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  # The peer must be TERM-RESISTANT before --restart signals it, or the test races
  # node's startup: a TERM landing before the handler is installed kills the peer,
  # the arm then legitimately steals the free lock and reports `started`, and the
  # case under test never happens. Have node announce readiness only AFTER the
  # handler is installed, and wait for that.
  node -e 'process.on("SIGTERM", () => {}); require("fs").writeFileSync(process.argv[1], "ready"); setTimeout(() => {}, 300000)' "$dir/peer.ready" &
  peer=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/peer.ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$dir/peer.ready" ] || fail "TERM-resistant peer never became ready"
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "restart did not exit zero after reporting healthy peer (status $status): $(cat "$out")"
  grep -qF "watcher: healthy pid=$peer" "$out" || fail "restart did not report the healthy peer: $(cat "$out")"
  ! grep -qF 'watcher: attached' "$out" || fail "restart attached to a peer watcher instead of preserving restart ownership contract"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "watch restart reports a healthy peer without attaching to it"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
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
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after seed died (status $status)"
  pass "arm attaches to a live fresh watcher and exits only when that cycle ends"
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
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
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
  # The inversion at the heart of the reaped-background-task fix: a signalled arm
  # is only the FOLLOWER, so it must stand down and leave the detached watcher -
  # the actual supervision - running. The old shape killed its watcher child here,
  # which is exactly how a harness reap took supervision down.
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-standdown)
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
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP stand-down check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || fail "no watcher held the lock before HUP"
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  sleep 0.5
  is_live_non_zombie "$lock_pid" || fail "HUP killed the detached watcher; it must survive its follower"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
    || fail "detached watcher lost the singleton lock after its arm was signalled"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "arm left an arm-scoped temp output behind"
  kill "$lock_pid" 2>/dev/null || true
  pass "a signalled arm stands down without killing the detached watcher"
}

test_watcher_survives_arm_process_group_sigterm() {
  # The reproduction of the reported bug, at the level the harness actually acts:
  # the reaper SIGTERMs the background task's whole PROCESS GROUP. Run the arm in
  # its own process group, signal that GROUP, and require the watcher to keep the
  # lock and a fresh beacon - i.e. supervision stays up, which is the acceptance
  # criterion. A same-process-group child (the old shape) dies to this signal.
  local dir state fakebin armout armpid pgid lock_pid i beat_before beat_after
  dir=$(make_case arm-reap-survival)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # setsid(1) does not exist on macOS; perl fork+setpgrp is the portable way to
  # give the arm its own killable process group, mirroring a harness background task.
  perl -e 'use POSIX (); my $pid = fork; die unless defined $pid;
    if (!$pid) { POSIX::setsid(); exec @ARGV; } print "$pid\n";' \
    env PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bash -c "\"$WATCH_ARM\" > \"$armout\" 2>&1" > "$dir/armpid"
  armpid=$(cat "$dir/armpid")
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm never started a watcher: $(cat "$armout" 2>/dev/null)"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || fail "no watcher held the lock before the reap"
  pgid=$(ps -o pgid= -p "$armpid" | tr -d ' ')
  [ -n "$pgid" ] || fail "could not read the arm's process group"
  [ "$(ps -o pgid= -p "$lock_pid" | tr -d ' ')" != "$pgid" ] \
    || fail "watcher shares the arm's process group; a group-wide reap would kill it"
  beat_before=$(stat_mtime_portable "$state/.last-watcher-beat")
  # Reap the arm exactly as the harness does: SIGTERM the whole process group.
  kill -TERM -"$pgid" 2>/dev/null || fail "could not signal the arm's process group"
  # The arm is deliberately NOT this shell's child here (it has its own process
  # group), so poll it rather than `wait` on it.
  i=0
  while [ "$i" -lt 80 ] && kill -0 "$armpid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$armpid" 2>/dev/null || fail "the arm survived the SIGTERM of its own process group"
  sleep 2
  is_live_non_zombie "$lock_pid" || fail "REGRESSION: the process-group reap killed the watcher - supervision is off"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
    || fail "watcher lost the singleton lock after the reap"
  beat_after=$(stat_mtime_portable "$state/.last-watcher-beat")
  [ -n "$beat_after" ] || fail "watcher stopped writing its liveness beacon after the reap"
  [ "$beat_after" -ge "${beat_before:-0}" ] || fail "watcher beacon went backwards after the reap"
  kill "$lock_pid" 2>/dev/null || true
  pass "the watcher survives a SIGTERM of the arm's whole process group (the harness reap)"
}

test_watcher_idle_self_exit() {
  # Orphan control for a now-detached watcher. It must rest only when NOTHING in
  # the home needs supervising, and must keep running while any one of the three
  # conditions says otherwise - a watcher a live session still expects must never
  # be killed by this.
  local dir state fakebin out pid status row
  # (1) Empty fleet, no X mode, not afk -> idle-exit after the configured polls.
  dir=$(make_case idle-exit)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_IDLE_EXIT_POLLS=2 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 120
  status=$?
  [ "$status" -eq 0 ] || fail "idle watcher did not exit cleanly (status $status)"
  grep -qF 'watcher: idle-exit' "$out" || fail "idle watcher did not report its idle-exit: $(cat "$out")"
  # An idle-exit is NOT a wake: it must not be mistaken for one by the arm or drain.
  ! grep -qE '^(signal:|stale:|check:|heartbeat)' "$out" \
    || fail "idle-exit line looks like an actionable wake reason"

  # (2) Each condition alone must KEEP the watcher alive past the same threshold.
  # An armed check is work the watcher owes whether or not a task is still in
  # flight, so ANY state/*.check.sh holds it - the X-mode relay shim is just one of
  # them, and a per-task poll (a merged-PR check) must not be silently dropped.
  for row in in-flight-task x-mode armed-check afk; do
    dir=$(make_case "idle-exit-held-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    out="$dir/watch.out"
    case "$row" in
      in-flight-task) printf 'project=x\n' > "$state/task.meta" ;;
      x-mode)         printf 'exit 0\n' > "$state/x-watch.check.sh" ;;
      armed-check)    printf 'exit 0\n' > "$state/task.check.sh" ;;
      afk)            : > "$state/.afk" ;;
    esac
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_IDLE_EXIT_POLLS=2 \
      FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    sleep 5
    is_live_non_zombie "$pid" || fail "watcher idle-exited despite '$row' - it is still needed: $(cat "$out")"
    ! grep -qF 'watcher: idle-exit' "$out" || fail "watcher reported idle-exit despite '$row'"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  pass "watcher idle-exits only with an empty fleet, no armed checks, and away mode off"
}

test_detach_spawn_contract() {
  # Every detach backend the host actually has must meet ONE contract, because
  # supervision must never be unable to start: the process lands in its OWN process
  # group (what a group-wide harness reap cannot reach), inherits the environment,
  # reads /dev/null, sends stdout AND stderr to the named file, and the spawner
  # prints its pid. macOS has no setsid(1) and exercises perl alone; a host with
  # both must not be able to tell them apart.
  local dir probe impl out pid pgid i
  dir=$(make_case detach-spawn)
  probe="$dir/probe.sh"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
printf 'pid=%s\n' "$$"
printf 'pgid=%s\n' "$(ps -p $$ -o pgid= | tr -d ' ')"
printf 'stdin=[%s]\n' "$(cat)"
printf 'env=%s\n' "${FM_DETACH_PROBE:-unset}"
printf 'to-stderr\n' >&2
SH
  chmod +x "$probe"
  for impl in setsid perl; do
    command -v "$impl" >/dev/null 2>&1 || continue
    out="$dir/$impl.out"
    pid=$(FM_DETACH_PROBE=inherited bash -c '. "$1"; . "$2"; "fm_detach_spawn_$3" "$4" "$5"' _ "$LIB" "$DETACH_LIB" "$impl" "$out" "$probe") \
      || fail "fm_detach_spawn_$impl could not launch the probe"
    case "$pid" in
      ''|*[!0-9]*) fail "fm_detach_spawn_$impl printed no detached pid (got '$pid')" ;;
    esac
    i=0
    while [ "$i" -lt 100 ]; do
      grep -qF 'to-stderr' "$out" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF 'to-stderr' "$out" || fail "$impl: the detached process's stderr never reached the output file: $(cat "$out" 2>/dev/null)"
    grep -qF "pid=$pid" "$out" || fail "$impl: the printed pid $pid is not the detached process's own pid: $(cat "$out")"
    pgid=$(sed -n 's/^pgid=//p' "$out")
    [ "$pgid" = "$pid" ] || fail "$impl: the detached process is not its own process-group leader (pgid '$pgid', pid '$pid')"
    [ "$pgid" != "$(ps -p $$ -o pgid= | tr -d ' ')" ] || fail "$impl: the detached process shares the caller's process group; a group reap would kill it"
    grep -qF 'stdin=[]' "$out" || fail "$impl: the detached process's stdin is not /dev/null: $(cat "$out")"
    grep -qF 'env=inherited' "$out" || fail "$impl: the detached process did not inherit the caller's environment"
  done
  pass "every detach backend on this host gives the process its own group, /dev/null stdin, and the named output file"
}

test_detach_spawn_fails_loud_with_no_backend() {
  # A host with neither setsid(1) nor perl cannot detach, so it cannot supervise:
  # say so on stderr and fail, rather than printing no pid and leaving the arm to
  # report an unexplained FAILED forever.
  local dir out err stdout rc
  dir=$(make_case detach-no-backend)
  out="$dir/spawn.out"
  err="$dir/spawn.err"
  stdout="$dir/spawn.stdout"
  rc=0
  bash -c '. "$1"; . "$2"; PATH=/nonexistent; fm_detach_spawn "$3" /bin/true' _ "$LIB" "$DETACH_LIB" "$out" > "$stdout" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm_detach_spawn reported success with no way to detach"
  [ ! -s "$stdout" ] || fail "fm_detach_spawn printed a pid it could not have launched: $(cat "$stdout")"
  grep -qF 'neither setsid(1) nor perl' "$err" || fail "fm_detach_spawn did not name the missing dependency: $(cat "$err")"
  pass "fm_detach_spawn fails loudly when the host has no way to detach"
}

test_detach_follow_is_bounded_by_process_identity() {
  # The follower must track the PROCESS it started following, not the number. A bare
  # kill -0 poll blocks forever once the pid is recycled: the harness task never
  # completes, the primary is never notified, and the wake the watcher already
  # enqueued sits undrained. A real pid recycle is not reproducible, so shadow
  # fm_pid_start (the start-time pin) to make the pid come back as a different
  # process, and require the follow to end rather than hang.
  local dir marker live follower status
  dir=$(make_case detach-follow-identity)
  marker="$dir/followed-once"
  sleep 300 &
  live=$!
  # The shadow keeps its "have we been called yet" state on DISK: fm_detach_follow
  # reads the start time through a command substitution, so an in-shell counter
  # would live and die in that subshell and never advance.
  bash -c '
    . "$1"; . "$2"
    marker=$4
    fm_pid_start() {
      if [ -e "$marker" ]; then
        printf "start-of-recycled-pid\n"
      else
        : > "$marker"
        printf "start-of-followed-process\n"
      fi
    }
    fm_detach_follow "$3" 0.05
  ' _ "$LIB" "$DETACH_LIB" "$live" "$marker" &
  follower=$!
  wait_for_exit "$follower" 50
  status=$?
  [ "$status" -ne 124 ] || fail "fm_detach_follow blocked on a live pid that no longer names the process it followed"
  [ "$status" -eq 0 ] || fail "fm_detach_follow exited non-zero on a recycled pid (status $status)"

  # Control, so the bound above cannot pass by giving up early: an UNCHANGED live
  # process keeps the follower blocked, and its exit is what releases it.
  bash -c '. "$1"; . "$2"; fm_detach_follow "$3" 0.05' _ "$LIB" "$DETACH_LIB" "$live" &
  follower=$!
  sleep 1
  is_live_non_zombie "$follower" || fail "fm_detach_follow returned while the process it followed was still alive"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  wait_for_exit "$follower" 80
  status=$?
  [ "$status" -eq 0 ] || fail "fm_detach_follow did not return when the followed process exited (status $status)"
  pass "fm_detach_follow follows a live process and ends when that pid is recycled"
}

test_attached_arm_surfaces_watcher_idle_exit() {
  # An attached arm must not complete EMPTY when the watcher it followed rested. An
  # idle-exit queues nothing, so an empty completion reads as a plain harness reap
  # (docs/supervision-protocols/claude.md step 9), firstmate re-arms a fresh watcher
  # onto the same empty fleet, and the home pays another full idle window plus a
  # spurious wake. It must surface the resting line the watcher actually wrote.
  local dir state fakebin watchout armout wpid armpid i status
  dir=$(make_case arm-attach-idle-exit)
  state="$dir/state"
  fakebin="$dir/fakebin"
  # The shared per-home output the arm launches the watcher into and reads back.
  watchout="$state/.watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_IDLE_EXIT_POLLS=8 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$watchout" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not attach to the idle watcher: $(cat "$armout")"
  wait_for_exit "$wpid" 200
  wait_for_exit "$armpid" 100
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after the watcher idle-exited (status $status)"
  grep -qF 'watcher: idle-exit' "$armout" \
    || fail "attached arm completed with no reason; firstmate would re-arm a fresh watcher on the empty fleet: $(cat "$armout")"
  ! grep -qE '^(signal:|stale:|check:|heartbeat)' "$armout" \
    || fail "attached arm printed a wake reason the watcher never wrote: $(cat "$armout")"
  pass "an attached arm surfaces the idle-exit of the watcher it followed"
}

test_arm_truncates_the_shared_watch_output() {
  # state/.watch.out is per-HOME, not per-arm, so the launching arm must truncate it
  # BEFORE the watcher starts. Otherwise a detached child that dies before it can
  # open the file (a failed exec, say) leaves the PREVIOUS cycle's reason line in
  # place, and the arm re-reads it as a phantom wake - reporting a successful wake to
  # the primary with no watcher running at all.
  local dir state fakebin armout watchout armpid i lock_pid
  dir=$(make_case arm-watch-out-truncate)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  watchout="$state/.watch.out"
  printf 'signal: task-x: blocked: a wake from a PREVIOUS cycle\n' > "$watchout"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start a watcher: $(cat "$armout")"
  ! grep -qF 'PREVIOUS cycle' "$watchout" || fail "arm left the previous cycle's reason line in the shared watch output"
  ! grep -qF 'PREVIOUS cycle' "$armout" || fail "arm reported a phantom wake off the previous cycle's leftover output"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill "$armpid" "$lock_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "an arming arm truncates the shared watch output before launching the watcher"
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
  local dir state fakebin armout peer beater identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
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
  # After the peer dies, the attached arm must exit 0 (same as pre-fork attach).
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
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
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" >/dev/null || fail "arm did not print the FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_pid_identity_is_locale_invariant() {
  # The watcher records its process identity under one locale; arm/guard/turn-end
  # re-read it under the machine's ambient locale. ps's lstart date format follows
  # LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR) would differ only
  # in the date portion and reject a genuinely live watcher. The fix pins LC_ALL=C
  # inside fm_pid_identity, so its output must be byte-identical regardless of the
  # caller's exported LC_ALL/LC_TIME. That invariant holds on any host because the
  # pin is internal, so this stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live baseline via_lc_all via_lc_time
  sleep 300 &
  live=$!
  baseline=$(LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_reports_healthy_peer_without_attaching
test_watcher_self_evicts_on_lock_takeover
test_watcher_idle_self_exit
test_detach_spawn_contract
test_detach_spawn_fails_loud_with_no_backend
test_detach_follow_is_bounded_by_process_identity
test_attached_arm_surfaces_watcher_idle_exit
test_arm_truncates_the_shared_watch_output
test_arm_attaches_and_waits_for_live_fresh_watcher
test_arm_starts_and_self_heals
test_arm_hup_stands_down_without_killing_the_watcher
test_watcher_survives_arm_process_group_sigterm
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
