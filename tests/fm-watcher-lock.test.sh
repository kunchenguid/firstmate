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

# An arm only reports its typed failure after wait_for_healthy_successor has
# spent the whole confirmation budget, so cases that wait for that failure must
# outlast the largest production default (30s on MSYS, 10s elsewhere - see
# ARM_CONFIRM_DEFAULT in bin/fm-watch-arm.sh). This is a ceiling spent only when
# an arm genuinely fails to exit; a passing case returns as soon as it does.
ARM_FAIL_EXIT_POLLS=400

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

drain_and_ack() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
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
  i=0
  while [ "$i" -lt 50 ] && ! grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null 2>&1; do
    sleep 0.02
    i=$((i + 1))
  done
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

test_live_missing_beacon_lock_is_actionable() {
  local dir state fakebin out err status typed_status identity live
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  sleep 300 &
  live=$!
  # A live holder that this home can positively identify as ITS OWN watcher,
  # whose beacon has aged. Recording the full identity is the whole point: it is
  # what separates "my watcher is inside a long phase" from "something else holds
  # this lock", and only the first of those may leave through the typed outcome.
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || fail "could not record the holder identity"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=30 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  # This case used to leave through a bare exit 1 with "heartbeat is stale" on
  # stderr, which reached the arm layer as "FAILED - exited 1 without an
  # actionable reason" and reported a working fleet's supervision as broken
  # (2026-09-04 supervision investigation). It now leaves through its own typed
  # status carrying the holder and the beacon age, so the arm can wait for that
  # holder instead. Still actionable, still not a failure.
  typed_status=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; printf %s "$FM_WATCHER_BUSY_HOLDER_STATUS"' _ "$LIB")
  [ "$status" = "$typed_status" ] \
    || fail "an identified live holder with a stale beacon exited $status, not the typed busy-holder status $typed_status"
  grep -F 'busy holder' "$out" >/dev/null \
    || fail "watcher did not name the busy holder: $(cat "$out" "$err" 2>/dev/null)"
  grep -F "pid=$live" "$out" >/dev/null \
    || fail "the typed busy-holder outcome did not name the holding pid"
  grep -E 'lock=[0-9]+s' "$out" >/dev/null \
    || fail "a missing beacon did not label its computed lock age truthfully: $(cat "$out")"
  is_live_non_zombie "$live" || fail "the identified holder was not left alone"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "an identified live holder with a stale beacon leaves through the typed busy-holder outcome"
}

# The other half of that distinction, and the reason the typed outcome is gated
# on identity at all: a live process holding the lock that this home CANNOT
# identify as its own watcher is not a busy watcher. Nothing can ever be
# confirmed behind that lock, so it must stay a loud failure rather than being
# waited on and then quietly excused.
test_unidentified_live_lock_holder_still_fails_loudly() {
  local dir state fakebin out err status typed_status live
  dir=$(make_case unidentified-live-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  sleep 300 &
  live=$!
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  typed_status=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; printf %s "$FM_WATCHER_BUSY_HOLDER_STATUS"' _ "$LIB")
  [ "$status" -ne 0 ] || fail "an unidentifiable live lock holder was treated as healthy"
  [ "$status" != "$typed_status" ] \
    || fail "an unidentifiable live holder used the typed busy-holder outcome; only an identity-matched watcher may"
  grep -F 'heartbeat is stale' "$err" >/dev/null \
    || fail "an unidentifiable live holder did not explain itself loudly: $(cat "$out" "$err" 2>/dev/null)"
  is_live_non_zombie "$live" || fail "the unrelated live lock holder was signalled"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "an unidentifiable live lock holder stays a loud failure, never a busy holder"
}

test_guard_warnings() {
  # The guard no longer reports watcher liveness at all: the passive
  # "WATCHER DOWN - SUPERVISION IS OFF" banner was removed for every supervision
  # model after the 2026-09-04 investigation showed it could not tell a working
  # watcher from a stopped one. What this case pins now is that the removal was
  # complete and did not take the independent queued-wakes warning with it:
  #   (1) watcher down + queued wakes: the queue warning is the ONLY output, and
  #       nothing describes watcher liveness, beacon age or supervision repair.
  #   (2) a fresh watcher and an empty queue: total silence, as before.
  local dir state err pid identity
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here. Pin Claude so the host runner's harness ancestry cannot change it.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  ! grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "the removed watcher banner is back"
  ! grep -F 'SUPERVISION IS OFF' "$err" >/dev/null || fail "the removed supervision-off text is back"
  ! grep -F 'task(s) in flight' "$err" >/dev/null || fail "guard still reports an in-flight count for watcher liveness"
  ! grep -F 'last beat' "$err" >/dev/null || fail "guard still reports beacon age"
  ! grep -F 'watcher still down' "$err" >/dev/null || fail "the removed episode reminder is back"
  # The queue warning must be the whole of it: one non-blank line.
  [ "$(grep -c -v '^[[:space:]]*$' "$err")" -eq 1 ] \
    || fail "guard printed more than the queued-wakes warning: $(cat "$err")"

  # (2) live watcher plus fresh beacon, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") || fail "could not identify fresh guard watcher"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so this stays a pure
  # assertion about guard output.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned with a live watcher and fresh beacon: $(cat "$err")"
  pass "guard reports no watcher liveness, keeps the queued-wakes warning, and stays silent when live and fresh"
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
  local dir state fakebin out live pid i
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
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" \
    && fail "restart did not surface recovery after replacing a reused-pid lock"
  wait "$pid" 2>/dev/null || true
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "restart replaced reused-pid lock without surfacing recovery: $(cat "$out")"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart preserves recovery without signaling a reused pid"
}

test_watch_restart_attaches_to_healthy_peer() {
  local dir state fakebin out peer_ready peer identity armpid status i
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_ready="$dir/peer.ready"
  node -e 'const fs = require("node:fs"); process.on("SIGTERM", () => {}); fs.writeFileSync(process.argv[1], "ready\n"); setTimeout(() => {}, 300000)' "$peer_ready" &
  peer=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$peer_ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$peer_ready" ]; then
    kill -KILL "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "TERM-resistant peer did not become ready"
  fi
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$out" || fail "restart did not attach to the verified healthy peer: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "restart arm exited instead of following the healthy peer"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "restart arm did not fail after its attached peer ended without a successor (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$out" || fail "restart arm did not surface the attached cycle end"
  pass "watch restart attaches to a verified healthy peer and later surfaces a successor gap"
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
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    && [ -s "$state/.watch.lock/pid-identity" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    || fail "watcher did not finish publishing its lock ownership"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_self_eviction_is_loud_without_successor() {
  local dir state fakebin armout armpid watcher_pid status i
  dir=$(make_case arm-self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # The arm's confirmation budget bounds a REAL child startup (fork, exec, lock
  # acquisition, beacon publication), so this case holds the arm to production's
  # own budget rather than a shrunken fixture one: a one-second budget turned
  # ordinary CPU contention into an honest "FAILED - no live watcher with a fresh
  # beacon" and broke this case's premise under full-suite load (issue #2844).
  # It stays at the production default rather than something roomier because the
  # same budget bounds the successor wait this case deliberately spends below.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "arm did not start before self-eviction check"

  # A live but identity-mismatched replacement lock makes the owned watcher
  # self-evict normally. With no verified successor, the arm must turn that
  # otherwise clean empty close into the typed nonzero failure.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "self-evicted arm did not fail nonzero (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "self-evicted arm omitted the typed cycle-end failure"
  grep -q "reason=unexpected-clean-exit" "$state/.watch-cycle-exits.log" || fail "self-evicted cycle was not classified in the lifecycle ledger"
  pass "arm turns clean self-eviction without a successor into a typed failure"
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
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
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
  # After the seed dies without a successor, the attached arm must fail loudly.
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after seed died (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a live fresh watcher and fails loudly when that cycle has no successor"
}

test_attached_arm_signal_is_recorded_in_cycle_ledger() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-signal-ledger)
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
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before signal"
  kill -TERM "$armpid" 2>/dev/null || fail "could not signal the attached arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 143 ] || fail "attached arm did not exit with TERM status (got $status)"
  grep -q "arm_pid=$armpid.*watcher_pid=$wpid.*origin=attached.*exit_code=143.*signal=TERM.*reason=arm-interrupted" "$state/.watch-cycle-exits.log" \
    || fail "attached arm signal was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "signaling an attached arm terminated the peer watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm signals record a classified lifecycle entry"
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
      if [ "$row" = dead-pid ]; then
        is_live_non_zombie "$armpid" || break
      else
        grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      fi
      sleep 0.1; i=$((i + 1))
    done
    if [ "$row" = dead-pid ]; then
      is_live_non_zombie "$armpid" \
        && fail "arm did not surface recovery after reclaiming a dead-pid lock"
      wait "$armpid" 2>/dev/null || true
      grep -F 'check: rearm-resurface' "$armout" >/dev/null \
        || fail "arm reclaimed dead-pid lock without surfacing recovery: $(cat "$armout")"
      continue
    fi
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts cleanly and resurfaces recovery after a dead-pid lock"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
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
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register immediate-wake custom check"
  rc=0
  # This case asserts wake propagation, not the confirmation deadline, and its
  # child must also run the registered check before exiting: measured at 1.9-2.3s
  # idle but 9.1-13.1s at 3x CPU oversubscription, against an 11s production
  # budget. An explicit budget takes the deadline out of the assertion and costs
  # nothing on a passing run, because the arm returns as soon as the child
  # settles (issue #2844).
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=60 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate check wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer identity armpid status i
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
  # Same budget contract as the self-eviction case: the owned child's real
  # startup and stand-down happen inside the arm's confirmation window, so the
  # window stays production-sized (issue #2844).
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  # Synchronize on the owned child declining the live peer lock before making
  # the peer healthy. Sleeping for the same budget the arm spends made this
  # regression fixture race the confirmation deadline under full-suite load,
  # rather than testing the intended successor-handshake boundary.
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "arm child did not stand down behind the peer watcher"
  touch "$state/.last-watcher-beat"
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies without a successor, the attached arm must fail loudly.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after peer died (status $status): $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "peer-attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a peer watcher after child stands down and surfaces a missing successor"
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
  grep -F 'watcher: FAILED' "$armout" >/dev/null || fail "arm did not print a typed FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_cycle_exit_ledger_links_successor_and_stays_bounded() {
  local dir state fakebin armout check_file first_arm successor_arm successor_pid i size iteration
  dir=$(make_case cycle-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/first-arm.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'done: synthetic cycle\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register cycle-ledger check"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  first_arm=$!
  wait "$first_arm" || fail "first ledger cycle did not surface its actionable wake"
  grep -q "arm_pid=$first_arm.*reason=actionable-check.*successor=none" "$state/.watch-cycle-exits.log" \
    || fail "first ledger record omitted its actionable classification"
  drain_and_ack "$state" || fail "first ledger wake handling acknowledgement failed"

  rm -f "$check_file" "$state/task.check-trust"
  armout="$dir/successor-arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_PREDECESSOR_ARM_PID="$first_arm" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  successor_arm=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  successor_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$successor_pid" "$armout" || fail "successor ledger cycle did not start"
  grep -q "arm_pid=$first_arm.*successor=started:$successor_pid" "$state/.watch-cycle-exits.log" \
    || fail "predecessor ledger record was not linked to its verified successor"
  kill -HUP "$successor_arm" 2>/dev/null || true
  wait "$successor_arm" 2>/dev/null || true
  # The forced interruption is a watcher-down interval. Consume the prior
  # delivered wake before beginning independent ledger cycles, just as the
  # recovery handling turn does, so this fixture does not intentionally carry a
  # durable wake into the next arm.
  drain_and_ack "$state" || fail "recovery drain after forced arm interruption failed"

  # Produce enough short cycles to cross a deliberately small cap. The cap is
  # applied by the arm layer itself and keeps only complete ledger records.
  iteration=0
  while [ "$iteration" -lt 6 ]; do
    armout="$dir/bounded-$iteration.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_LOG_MAX_BYTES=1400 FM_WATCH_CYCLE_LOG_KEEP_LINES=2 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    successor_arm=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "bounded ledger cycle $iteration did not start"
    kill -HUP "$successor_arm" 2>/dev/null || true
    wait "$successor_arm" 2>/dev/null || true
    drain_and_ack "$state" \
      || fail "recovery drain after bounded ledger cycle $iteration failed"
    iteration=$((iteration + 1))
  done
  size=$(wc -c < "$state/.watch-cycle-exits.log" | tr -d '[:space:]')
  [ "$size" -le 1400 ] || fail "cycle ledger exceeded its configured cap ($size bytes)"
  ! grep -v '^arm_pid=.*watcher_pid=.*started_at=.*ended_at=.*exit_code=.*signal=.*reason=.*beacon_age=.*lock_before=.*lock_after=.*successor=' "$state/.watch-cycle-exits.log" | grep . >/dev/null \
    || fail "bounded lifecycle ledger contains a partial or malformed record"
  pass "cycle-exit ledger links a verified successor and remains size-capped"
}

test_stopped_watcher_is_live_but_stale_then_exit_is_classified() {
  local dir state fakebin armout armpid watcher_pid i status
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  kill -CONT "$watcher_pid" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated stopped-watcher cycle did not surface nonzero (status $status)"
  grep -Eq 'reason=(nonzero-exit|signal-exit)' "$state/.watch-cycle-exits.log" \
    || fail "terminated watcher exit was not classified in the lifecycle ledger"
  pass "SIGSTOP distinguishes live PID from stale beacon and termination records the exit class"
}

# Stop a fixture process and actually get rid of it. TERM first, then a hard stop
# after a bounded wait: a SIGSTOPped fixture never handles TERM, and leaving one
# behind strands the runner, because an orphan keeps its stdout open long after
# the script that started it has finished.
reap() {  # <pid>
  local pid=$1 i=0
  [ -n "$pid" ] || return 0
  kill -CONT "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# --- a live monitor process is never terminated on age ----------------------
#
# 2026-09-04 supervision investigation: a live, identity-matched watcher whose
# beacon had aged was reported as "auto-arm FAILED - exited 1 without an
# actionable reason", and the auto-arm re-ran the identical predicate one second
# later (both refusals landed at epochs 1788501895 and 1788501896). The watcher
# was working the whole time.
#
# The arm now waits for such a holder and attaches when it beats again. It does
# NOT stop it, replace it, or start a second watcher beside it: an aged beacon is
# a suspected stall, and identity proves only WHICH process holds the lock, never
# that the process is stuck. The captain ruled on 2026-09-05 that a running
# monitor process is never terminated on age, a missing heartbeat, or an expired
# wait. The SIGSTOP fixture is the strongest stalled holder available, and is
# used here precisely because even that one must survive.

test_young_missing_beacon_holder_is_not_reported_as_a_failure() {
  local dir state fakebin armout armpid watcher_pid i out second secondpid held blocked=0
  dir=$(make_case busy-holder-typed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  second="$dir/second.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -z "$watcher_pid" ]; then
    reap "$armpid"
    fail "no watcher started for the busy-holder fixture"
  fi
  # Stall it before its first beacon is observable. Then retire the
  # arm that started it, so what follows observes ONE arm meeting one stalled
  # holder. The first arm is a fixture, not a participant; left alive it reacts
  # to its own stopped child and muddies the observation.
  kill -STOP "$watcher_pid" 2>/dev/null || true
  rm -f "$state/.last-watcher-beat"
  kill -KILL "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true

  # A second arm now meets a live holder with a young lock and no beacon. Run it in the
  # BACKGROUND behind a bounded wait: blocking on the stalled holder is itself a
  # failure, and a foreground call would hang the whole suite.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=2 FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$second" 2>&1 &
  secondpid=$!
  i=0
  while [ "$i" -lt 300 ]; do
    kill -0 "$secondpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$secondpid" 2>/dev/null && blocked=1
  out=$(cat "$second" 2>/dev/null || true)
  held=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  # Observations are complete: tear every fixture down BEFORE asserting, so no
  # assertion can leave a stopped watcher holding the runner's stdout open.
  reap "$secondpid"
  reap "$watcher_pid"

  [ "$blocked" -eq 0 ] \
    || fail "the arm blocked indefinitely on a stalled holder instead of returning"
  [ "$held" = "$watcher_pid" ] \
    || fail "the live holder lost the lock (lock names '$held', holder was $watcher_pid)"
  # The arm announces every watcher it starts, so its own output is the
  # authoritative observable for "a successor was launched".
  case "$out" in
    *"watcher: started pid="*)
      fail "a successor watcher was started alongside the live holder: $out" ;;
  esac
  case "$out" in
    *"auto-arm FAILED"*|*"FAILED - watcher cycle exited"*)
      fail "a live holder was reported as a failure: $out" ;;
  esac
  case "$out" in
    *"busy holder"*) ;;
    *) fail "a live holder with no beacon produced no typed outcome: $out" ;;
  esac
  case "$out" in
    *"lock="*) ;;
    *) fail "a missing beacon was not reported truthfully as lock age: $out" ;;
  esac
  pass "a young live holder without a beacon is left alone and not reported failed"
}

test_busy_holder_replacement_stays_a_loud_failure() {
  local dir state arm out status first second identity held second_alive=0
  dir=$(make_case busy-holder-replacement)
  state="$dir/state"
  mkdir -p "$dir/bin"
  cp "$WATCH_ARM" "$dir/bin/fm-watch-arm.sh"
  cp "$LIB" "$dir/bin/fm-wake-lib.sh"
  chmod +x "$dir/bin/fm-watch-arm.sh"
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: busy holder pid=%s beacon=20s (grace 2s)\n' "$FM_TEST_FIRST"
kill -TERM "$FM_TEST_FIRST" 2>/dev/null || true
rm -rf "$FM_STATE_OVERRIDE/.watch.lock"
mkdir "$FM_STATE_OVERRIDE/.watch.lock"
printf '%s\n' "$FM_TEST_SECOND" > "$FM_STATE_OVERRIDE/.watch.lock/pid"
touch -t 200001010000 "$FM_STATE_OVERRIDE/.last-watcher-beat"
exit 64
SH
  chmod +x "$dir/bin/fm-watch.sh"
  sleep 60 &
  first=$!
  sleep 60 &
  second=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$first") \
    || fail "could not identify the original busy holder"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$first" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$dir/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch -t 200001010000 "$state/.last-watcher-beat"
  arm="$dir/bin/fm-watch-arm.sh"
  status=0
  FM_TEST_FIRST="$first" FM_TEST_SECOND="$second" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=2 FM_ARM_CONFIRM_TIMEOUT=1 \
    "$arm" > "$dir/arm.out" 2>&1 || status=$?
  out=$(cat "$dir/arm.out")
  held=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  is_live_non_zombie "$second" && second_alive=1
  kill "$first" "$second" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "an unidentified replacement holder closed the arm quietly: $out"
  case "$out" in
    *"watcher: FAILED"*) ;;
    *) fail "an unidentified replacement holder was not reported loudly: $out" ;;
  esac
  [ "$held" = "$second" ] && [ "$second_alive" -eq 1 ] \
    || fail "the replacement holder was signalled or displaced"
  pass "a replacement holder must be reverified before a busy wait can close quietly"
}

test_busy_holder_uses_shared_guard_grace() {
  local dir state arm holder identity refresher armpid i out early_attach=0 attached=0
  dir=$(make_case busy-holder-threshold)
  state="$dir/state"
  mkdir -p "$dir/bin"
  cp "$WATCH_ARM" "$dir/bin/fm-watch-arm.sh"
  cp "$LIB" "$dir/bin/fm-wake-lib.sh"
  chmod +x "$dir/bin/fm-watch-arm.sh"
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
mkdir "$FM_STATE_OVERRIDE/.watch.lock"
printf '%s\n' "$FM_TEST_HOLDER" > "$FM_STATE_OVERRIDE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$FM_STATE_OVERRIDE/.watch.lock/fm-home"
printf '%s\n' "$0" > "$FM_STATE_OVERRIDE/.watch.lock/watcher-path"
printf '%s\n' "$FM_TEST_IDENTITY" > "$FM_STATE_OVERRIDE/.watch.lock/pid-identity"
printf 'watcher: busy holder pid=%s beacon=2s (grace 1s)\n' "$FM_TEST_HOLDER"
exit 64
SH
  chmod +x "$dir/bin/fm-watch.sh"
  sleep 60 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$holder") \
    || fail "could not identify the threshold holder"
  touch "$state/.last-watcher-beat"
  sleep 2
  (
    i=0
    while [ "$i" -lt 50 ] && [ ! -e "$state/.watch.lock/pid" ]; do
      sleep 0.02
      i=$((i + 1))
    done
    sleep 1
    touch "$state/.last-watcher-beat"
  ) &
  refresher=$!
  arm="$dir/bin/fm-watch-arm.sh"
  FM_TEST_HOLDER="$holder" FM_TEST_IDENTITY="$identity" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 \
    FM_ARM_CONFIRM_TIMEOUT=2 "$arm" > "$dir/arm.out" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    grep -qF "watcher: busy holder pid=$holder" "$dir/arm.out" 2>/dev/null && break
    kill -0 "$armpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  sleep 0.2
  grep -qF "watcher: attached pid=$holder" "$dir/arm.out" 2>/dev/null && early_attach=1
  i=0
  while [ "$i" -lt 50 ]; do
    if grep -qF "watcher: attached pid=$holder" "$dir/arm.out" 2>/dev/null; then
      attached=1
      break
    fi
    kill -0 "$armpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  out=$(cat "$dir/arm.out" 2>/dev/null || true)
  reap "$armpid"
  reap "$holder"
  wait "$refresher" 2>/dev/null || true
  [ "$early_attach" -eq 0 ] || fail "the arm attached while the watcher still classified its holder as stale: $out"
  [ "$attached" -eq 1 ] || fail "the arm did not attach after the unchanged holder beat again: $out"
  case "$out" in *"watcher: FAILED"*) fail "the unchanged holder was failed loudly: $out" ;; esac
  pass "busy-holder validation and attachment use the shared guard grace"
}

test_initial_attachment_uses_shared_guard_grace() {
  local dir state holder identity armpid i out held holder_alive=0 attached=0
  dir=$(make_case initial-threshold-attach)
  state="$dir/state"
  sleep 60 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$holder") \
    || fail "could not identify the initial threshold holder"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  sleep 2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=1 FM_WATCHER_STALE_GRACE=30 FM_ARM_CONFIRM_TIMEOUT=1 \
    "$WATCH_ARM" > "$dir/arm.out" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    if grep -qF "watcher: attached pid=$holder" "$dir/arm.out" 2>/dev/null; then
      attached=1
      break
    fi
    kill -0 "$armpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  out=$(cat "$dir/arm.out" 2>/dev/null || true)
  held=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  is_live_non_zombie "$holder" && holder_alive=1
  reap "$armpid"
  reap "$holder"
  [ "$attached" -eq 0 ] || fail "a removed stale-grace override displaced the shared guard grace: $out"
  case "$out" in *"watcher: FAILED"*) fail "the live holder failed loudly under the shared grace: $out" ;; esac
  case "$out" in *"busy holder"*) ;; *) fail "the shared grace did not classify the stale holder: $out" ;; esac
  [ "$held" = "$holder" ] && [ "$holder_alive" -eq 1 ] \
    || fail "the initial threshold holder was signalled or replaced"
  pass "initial attachment uses only the shared guard grace"
}

test_recovering_holder_is_attached_to_not_replaced() {
  local dir state fakebin armout armpid watcher_pid i out second secondpid
  dir=$(make_case busy-holder-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  second="$dir/second.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -z "$watcher_pid" ]; then
    reap "$armpid"
    fail "no watcher started for the attach fixture"
  fi
  # Age the beacon so the next arm sees a busy holder, then let the holder beat
  # again mid-wait: the ordinary case of a slow phase completing. The holder is
  # never stopped here, so nothing can block on it.
  touch -t 200001010000 "$state/.last-watcher-beat"
  kill -KILL "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  ( sleep 2; touch "$state/.last-watcher-beat" ) >/dev/null 2>&1 &

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=8 FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$second" 2>&1 &
  secondpid=$!
  i=0
  while [ "$i" -lt 300 ]; do
    grep -qF "watcher: attached pid=$watcher_pid" "$second" 2>/dev/null && break
    kill -0 "$secondpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  out=$(cat "$second" 2>/dev/null || true)
  reap "$secondpid"
  reap "$watcher_pid"

  case "$out" in
    *"watcher: attached pid=$watcher_pid"*) ;;
    *) fail "the arm did not attach to the holder that beat again: $out" ;;
  esac
  case "$out" in
    *"watcher: started pid="*) fail "the arm replaced the recovering holder: $out" ;;
    *FAILED*) fail "attaching to a recovered holder reported a failure: $out" ;;
  esac
  pass "a holder that beats again mid-wait is attached to, not replaced"
}

test_pid_identity_is_locale_invariant() {
  # The portable fallback records its process identity under one locale, then
  # arm/guard/turn-end re-read it under the machine's ambient locale. ps's lstart
  # date format follows LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR)
  # would reject a genuinely live watcher. The fallback pins LC_ALL=C inside
  # fm_pid_identity, so its output must be byte-identical regardless of the caller's
  # exported LC_ALL/LC_TIME. This stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live no_proc fakebin locale_log baseline via_lc_all via_lc_time
  local real_first real_second observed
  sleep 300 &
  live=$!
  no_proc="$TMP_ROOT/no-proc"
  fakebin="$TMP_ROOT/locale-ps"
  locale_log="$TMP_ROOT/locale-ps.observed"
  mkdir -p "$fakebin"
  : > "$locale_log"
  # The stub renders lstart through date under whatever locale it inherits, so its
  # output really does change when the caller's locale leaks through. Dropping the
  # LC_ALL=C pin in fm_pid_identity therefore breaks the equality assertions below
  # on any host with a second locale installed, and the recorded LC_ALL below keeps
  # the pin asserted even where ko_KR.UTF-8 is missing and date falls back to C.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LC_ALL-<unset>}" >> "$FAKE_PS_LOCALE_LOG"
stamp=$(date -d @1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp=$(date -r 1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp='Mon Jul 28 20:00:00 2026'
printf '%s sleep 300\n' "$stamp"
SH
  chmod +x "$fakebin/ps"
  baseline=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  # Keep the real ps fallback exercised wherever it supports the portable -o fields.
  real_first=
  real_second=
  if LC_ALL=C ps -p "$live" -o lstart= -o command= >/dev/null 2>&1; then
    real_first=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
    real_second=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  while read -r observed; do
    [ "$observed" = C ] || fail "fm_pid_identity invoked ps without pinning LC_ALL=C (saw '$observed')"
  done < "$locale_log"
  if [ -n "$real_first" ]; then
    [ "$real_second" = "$real_first" ] \
      || fail "real ps fallback varied with exported LC_TIME (got '$real_second', want '$real_first')"
    pass "fm_pid_identity real ps fallback is locale-invariant"
  else
    pass "real ps fallback locale check skipped where ps -o lstart= is unsupported"
  fi
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

write_fake_proc_identity() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" > "$proc_root/$pid/stat"
  printf 'bash\0/path with spaces/fm-watch.sh\0--flag\0' > "$proc_root/$pid/cmdline"
}

test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse() {
  local dir state proc_root pid identity_key before after_time_jump after_pid_reuse
  dir=$(make_case proc-pid-identity)
  state="$dir/state"
  proc_root="$dir/proc"
  pid=4242
  identity_key=proc-starttime
  [ "$(uname)" != Linux ] || identity_key=linux-starttime
  mkdir -p "$proc_root"
  printf 'btime 1784094040\n' > "$proc_root/stat"
  write_fake_proc_identity "$proc_root" "$pid" 987654

  before=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read initial fake Linux process identity"
  printf 'btime 1784094016\n' > "$proc_root/stat"
  after_time_jump=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not re-read fake Linux process identity after btime change"

  [ "$after_time_jump" = "$before" ] \
    || fail "/proc process identity changed with btime (before '$before', after '$after_time_jump')"
  [ "$before" = "$identity_key=987654 cmdline-hex=62617368002f706174682077697468207370616365732f666d2d77617463682e7368002d2d666c616700" ] \
    || fail "/proc process identity did not combine parsed starttime field 22 with the full cmdline ('$before')"
  pass "/proc process identity ignores simulated btime changes"

  write_fake_proc_identity "$proc_root" "$pid" 987655
  after_pid_reuse=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read reused fake /proc pid identity"
  [ "$after_pid_reuse" != "$before" ] || fail "/proc process identity missed changed starttime for reused pid"
  pass "/proc process identity detects pid reuse"
}

test_stale_watch_reclaim_publishes_before_clear() {
  local dir state lockdir rc token
  dir=$(make_case stale-watch-publish-before-clear)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  mkdir -p "$lockdir"
  printf '99999999\n' > "$lockdir/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_remove_path() {
      if [ "$1" = "$STATE/.watch.lock" ]; then
        kill -KILL "${BASHPID:-$$}"
      fi
      return 1
    }
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted stale watcher reclaim unexpectedly completed"
  [ -e "$lockdir" ] || [ -L "$lockdir" ] \
    || fail "stale watcher lock cleared before recovery publication boundary"
  token=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_read "$2" || exit 1
    printf "%s\n" "$FM_RECOVERY_MARKER_TOKEN"
  ' _ "$LIB" "$state/.watcher-down") \
    || fail "stale watcher reclaim interruption left no durable recovery evidence"
  case "$token" in
    pending:downtime:*) ;;
    *) fail "stale watcher reclaim published invalid recovery evidence: $token" ;;
  esac

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" \
    || fail "successor could not reclaim watcher lock after interrupted clear"
  pass "stale watcher reclaim publishes durable recovery evidence before clear"
}

test_msys_pid_identity_uses_proc() {
  local live identity
  case "$(uname)" in
    MSYS*|MINGW*|CYGWIN*) ;;
    *)
      pass "MSYS /proc process identity regression skipped on non-Windows host"
      return
      ;;
  esac
  sleep 300 &
  live=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$identity" in
    proc-starttime=*" cmdline-hex="*) ;;
    *) fail "MSYS process identity did not use compatible /proc fields ('$identity')" ;;
  esac
  pass "MSYS process identity uses compatible /proc fields"
}

test_singleton_start
test_young_missing_beacon_holder_is_not_reported_as_a_failure
test_busy_holder_replacement_stays_a_loud_failure
test_busy_holder_uses_shared_guard_grace
test_initial_attachment_uses_shared_guard_grace
test_recovering_holder_is_attached_to_not_replaced
test_pid_identity_is_locale_invariant
test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse
test_msys_pid_identity_uses_proc
test_stale_watch_lock_reclaimed
test_stale_watch_reclaim_publishes_before_clear
test_live_missing_beacon_lock_is_actionable
test_unidentified_live_lock_holder_still_fails_loudly
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
test_watch_restart_attaches_to_healthy_peer
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
