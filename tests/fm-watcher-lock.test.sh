#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
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
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

fm_test_tmproot_into TMP_ROOT fm-watcher-lock-tests


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
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
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

test_lock_stale_steal_chain_is_bounded() {
  local dir state lockdir dead rc suffix i
  dir=$(make_case lock-stale-steal-chain)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir" "$lockdir.steal"
  printf '%s\n' "$dead" > "$lockdir/pid"
  printf '%s\n' "$dead" > "$lockdir.steal/pid"
  rc=0
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to recover a stale steal mutex (rc=$rc)"

  lockdir="$state/.bounded.lock"
  suffix=
  i=0
  while [ "$i" -le 9 ]; do
    mkdir "$lockdir$suffix"
    printf '%s\n' "$dead" > "$lockdir$suffix/pid"
    suffix="$suffix.steal"
    i=$((i + 1))
  done
  rc=0
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -ne 0 ] || fail "an excessive stale steal chain was recursively reclaimed"
  [ ! -e "$lockdir$suffix" ] && [ ! -L "$lockdir$suffix" ] || fail "stale steal recovery grew beyond its bounded guard depth"
  pass "stale steal mutex recovery is bounded"
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
  local dir state fakebin out peer peer_ready identity armpid status
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_ready="$dir/peer-ready"
  node -e '
    require("node:fs").writeFileSync(process.argv[1], "ready\n");
    process.on("SIGTERM", () => {});
    setTimeout(() => {}, 300000);
  ' "$peer_ready" &
  peer=$!
  if ! fm_test_wait_for_file "$peer_ready" "$peer" 0.02; then
    kill -KILL "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "healthy-peer fixture did not reach its stable post-exec identity"
  fi
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
  # Keep this lifecycle test out of unrelated first-cycle maintenance. The
  # beacon below is then a deterministic observation that the watcher has
  # entered its supervision loop and passed its ownership check.
  touch "$state/.last-check" "$state/.last-account-session-sync" "$state/.last-report-retention"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] &&
      [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] || fail "watcher did not reach the ownership-observation loop"
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
  # After the seed dies the attached arm must end, and must say so: no live cycle
  # exists any more, so it exits non-zero with the terminal line
  # (test_arm_attach_end_is_never_a_silent_false_attach owns that contract).
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 124 ] || fail "attached arm never returned after the seed died"
  [ "$status" -ne 0 ] || fail "attached arm exited zero after the seed died, reading as live supervision"
  pass "arm attaches to a live fresh watcher and exits only when that cycle ends"
}

test_arm_attach_end_is_never_a_silent_false_attach() {
  # REGRESSION: an `attached` line is true only at the instant it is printed, but
  # the caller reads the whole buffer after the task completes. The arm used to
  # exit 0 and SILENT when the attached holder stopped being healthy, leaving
  # `watcher: attached pid=<N>` as the caller's final word - a pid that no longer
  # passed the liveness proof, and a beacon age frozen at attach time and so
  # understated by the whole attach duration. The caller read that as live
  # supervision and ended its turn with nothing watching the fleet.
  #
  # The rows cover every way an attach can stop - the holder exits, the holder
  # wedges and its beacon goes stale, or this arm is signalled away - and all
  # assert the same thing: the LAST word is never a bare attach claim.
  local row dir state fakebin armout armpid status peer identity last claimed
  for row in holder-exited beacon-stale interrupted; do
    dir=$(make_case "arm-attach-end-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    peer=
    if [ "$row" = holder-exited ]; then
      # A genuinely live watcher holding the singleton, which then dies.
      PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
      peer=$!
      i=0
      while [ "$i" -lt 80 ]; do
        [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] && [ -e "$state/.last-watcher-beat" ] && break
        sleep 0.1
        i=$((i + 1))
      done
      [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] || fail "seed watcher ($row) did not take the lock"
    else
      # A live, identity-matched holder. The beacon-stale row later wedges it
      # (stops beating, never exits); the interrupted row leaves it healthy and
      # signals the arm instead.
      sleep 300 &
      peer=$!
      identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
      mkdir "$state/.watch.lock"
      printf '%s\n' "$peer" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi

    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm ($row) did not attach to the healthy holder: $(cat "$armout")"
    # The frozen reading must date itself, so a caller reading it later cannot
    # mistake an attach-time age for the age now.
    grep -qE "watcher: attached pid=$peer \(beacon [0-9]+s as of [0-9]{2}:[0-9]{2}:[0-9]{2}\)" "$armout" \
      || fail "arm ($row) attach line did not stamp when the beacon age was measured: $(cat "$armout")"

    # End the attach.
    case "$row" in
      holder-exited)
        kill -KILL "$peer" 2>/dev/null || true
        wait "$peer" 2>/dev/null || true
        ;;
      beacon-stale)
        touch -t 200001010000 "$state/.last-watcher-beat"
        ;;
      interrupted)
        kill -TERM "$armpid" 2>/dev/null || true
        ;;
    esac

    wait_for_exit "$armpid" 100
    status=$?
    [ "$status" -ne 124 ] || fail "arm ($row) never returned after the attached cycle ended"

    # The assertion that catches the bug: with the terminal line removed, the
    # buffer's final word is the stale `attached` claim.
    last=$(grep -v '^[[:space:]]*$' "$armout" | tail -1)
    case "$last" in
      *"watcher: attached"*)
        fail "arm ($row) left a bare attach claim as its final word: $last"
        ;;
    esac
    [ "$status" -ne 0 ] || fail "arm ($row) exited zero after the attach stopped, reading as live supervision"
    if [ "$row" = interrupted ]; then
      grep -qF "watcher: FAILED - attach interrupted" "$armout" \
        || fail "arm ($row) did not report that the attach was interrupted: $(cat "$armout")"
      # The holder is still fine here; the honest report is that WAKE DELIVERY
      # stopped, not that the watcher died.
      grep -qF "watcher pid=$peer is still live" "$armout" \
        || fail "arm ($row) did not distinguish a live holder from a dead one: $(cat "$armout")"
    else
      grep -qF "watcher: FAILED - attached cycle ended" "$armout" \
        || fail "arm ($row) did not report that the attached cycle ended: $(cat "$armout")"
      grep -qF "(was pid=$peer," "$armout" \
        || fail "arm ($row) terminal line did not name the holder whose cycle ended: $(cat "$armout")"
    fi

    # And the claim the caller would otherwise have believed really is false: no
    # watcher is live for this home at return.
    claimed=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ "$row" = holder-exited ]; then
      [ -z "$claimed" ] || ! kill -0 "$claimed" 2>/dev/null \
        || fail "arm ($row) fixture is wrong: a watcher is still live, so there was no false attach to catch"
    fi
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
  done
  pass "arm never leaves a bare attach claim as its final word when an attach stops"
}

test_arm_attach_end_after_peer_wake_preserves_the_wake() {
  # The DOMINANT production shape, and why the silent exit fired on nearly every
  # plain arm in a busy home: fm-watch.sh exits normally as soon as it surfaces a
  # wake, by design. So an attach routinely lasts only until the next wake, the
  # holder is gone moments after the `attached` line is printed, and the caller
  # reads a pid with no live process behind it. No watcher crash is involved.
  #
  # Two things must hold when that happens: the arm says the cycle ended, and the
  # wake the holder queued is still there for the caller to drain, because the
  # repair for the terminal line is "drain queued wakes, then re-arm".
  local dir state fakebin armout drain_out check_file peer armpid status i
  dir=$(make_case arm-attach-end-after-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  # Emits a wake only once the trigger exists, so the seed watcher blocks first
  # and lets the arm attach to a genuinely healthy holder.
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
[ -e "${FM_TEST_WAKE_TRIGGER:-/nonexistent}" ] || exit 0
printf 'merged: https://example.test/pr/9\n'
SH
  chmod +x "$check_file"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_TEST_WAKE_TRIGGER="$dir/trigger" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  peer=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] || fail "seed watcher did not take the lock"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_TEST_WAKE_TRIGGER="$dir/trigger" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not attach to the seed watcher: $(cat "$armout")"

  # The holder now does the normal thing: surface a wake and exit zero.
  touch "$dir/trigger"
  wait "$peer" 2>/dev/null \
    || fail "seed watcher did not exit cleanly after its wake, so this is not the normal-exit path"

  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: FAILED - attached cycle ended' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  wait_for_exit "$armpid" 100
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned after its holder woke and exited: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "arm exited zero after its holder woke and exited, reading as live supervision"
  # The cause text is deliberately not pinned: the holder releases its lock in an
  # EXIT trap and stays a not-yet-reaped zombie for a moment, so this race
  # honestly reports either "holder exited" or "lock no longer names that
  # watcher". Both are true; what must hold is that the ended cycle is reported
  # at all and names the holder.
  grep -qF 'watcher: FAILED - attached cycle ended' "$armout" \
    || fail "arm did not report the ended cycle on the normal peer-wake exit (status $status): $(cat "$armout")"
  grep -qF "(was pid=$peer," "$armout" \
    || fail "arm terminal line did not name the holder whose cycle ended: $(cat "$armout")"

  # The queued wake must survive: the caller's repair is drain-then-re-arm, so
  # reporting the ended cycle must not cost the wake that ended it.
  FM_HOME="$dir" "$DRAIN" > "$drain_out" || fail "drain after the attached holder's wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F 'merged: https://example.test/pr/9' >/dev/null \
    || fail "the wake that ended the attach was lost: $(cat "$drain_out")"
  pass "arm reports the ended cycle when its holder wakes and exits normally, and the wake survives to drain"
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
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=0.1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
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

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
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
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
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
  # After the peer dies the attached arm must end the same way as the pre-fork
  # attach: non-zero, with the terminal line, never a silent zero.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 124 ] || fail "attached arm never returned after the peer died: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "attached arm exited zero after peer died, reading as live supervision: $(cat "$armout")"
  grep -qF "watcher: FAILED - attached cycle ended" "$armout" \
    || fail "attached arm did not report that the peer's cycle ended: $(cat "$armout")"
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

test_watcher_bounded_command_reaped_on_owner_shutdown() {
  local dir marker owner child bounded_owner i
  dir=$(make_case bounded-owner-shutdown)
  marker="$dir/child.pid"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1"
    run_bounded 30 bash -c '\''echo "$$" > "$1"; sleep 30'\'' _ "$2"
  ' _ "$WATCH" "$marker" &
  owner=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$marker" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$marker" ] || { kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true; fail "bounded watcher command never started"; }
  child=$(cat "$marker")
  bounded_owner=$(ps -axo pid=,ppid= | awk -v parent="$owner" '$2 == parent { print $1; exit }')
  [ -n "$bounded_owner" ] \
    || { kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true; fail "bounded watcher owner was not observable"; }
  fm_super_stop_watcher "$owner"
  wait "$owner" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && is_live_non_zombie "$child"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$child" \
    || { kill -KILL "$child" 2>/dev/null || true; fail "watcher shutdown orphaned bounded child $child"; }
  ! is_live_non_zombie "$bounded_owner" \
    || { kill -KILL "$bounded_owner" 2>/dev/null || true; fail "watcher shutdown orphaned bounded owner $bounded_owner"; }
  pass "watcher shutdown terminates and reaps its bounded command tree"
}

if [ "${FM_TEST_FOCUSED:-}" = self-evict ]; then
  test_watcher_self_evicts_on_lock_takeover
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = stale-steal-chain ]; then
  test_lock_stale_steal_chain_is_bounded
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = bounded-owner-shutdown ]; then
  test_watcher_bounded_command_reaped_on_owner_shutdown
  exit 0
fi

test_singleton_start
test_pid_identity_is_locale_invariant
test_watcher_bounded_command_reaped_on_owner_shutdown
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_stale_steal_chain_is_bounded
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_reports_healthy_peer_without_attaching
test_watcher_self_evicts_on_lock_takeover
test_arm_attaches_and_waits_for_live_fresh_watcher
test_arm_attach_end_is_never_a_silent_false_attach
test_arm_attach_end_after_peer_wake_preserves_the_wake
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
