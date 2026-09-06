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
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line pid identity
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  # Pin Claude so the host test runner's harness ancestry cannot change this fixture.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
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
  grep -F 'watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard banner missing neutral automatic-recovery guidance"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard did not order neutral automatic recovery after drain"
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
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

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
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned with a live watcher and fresh beacon: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when live and fresh"
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

test_self_triggered_restart_refuses_to_attach_to_the_pid_it_termed() {
  # F2. A watcher runs its TERM handler only when its current foreground wait
  # returns, and that wait is bounded by FM_POLL rather than by anything the arm
  # controls, so a TERMed watcher can stay alive far longer than the restart's
  # bounded exit wait. A self-triggered restart that falls through then re-verifies
  # and announces a VERIFIED attach to a process it has itself told to die - the
  # branch's own defect, recreated by its own recovery path.
  # The peer here is TERM-resistant, which is the deterministic stand-in for that
  # deferral: both leave the arm looking at a live, healthy, identity-matched lock
  # holder that it has already signalled.
  # Only the SELF-triggered restart is guarded, so this case differs from
  # test_watch_restart_attaches_to_healthy_peer in exactly one variable,
  # FM_ARM_RESTART_DEPTH, and asserts the opposite outcome. An operator restart
  # must still attach; a restart the arm chose for itself must not.
  local dir state fakebin out peer_ready peer_termed peer identity armpid status i
  dir=$(make_case restart-self-triggered-termed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_ready="$dir/peer.ready"
  # The peer records the moment it is signalled, so the fixture can refresh the
  # beacon strictly AFTER the stop is issued rather than racing it. It ignores
  # the signal otherwise, which is the deterministic stand-in for a watcher whose
  # handler is deferred behind its current foreground wait.
  peer_termed="$dir/peer.termed"
  node -e 'const fs = require("node:fs"); const t = process.argv[2]; process.on("SIGTERM", () => { try { fs.writeFileSync(t, "1"); } catch (e) {} }); fs.writeFileSync(process.argv[1], "ready\n"); setTimeout(() => {}, 300000)' "$peer_ready" "$peer_termed" &
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
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") \
    || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # A STALE beacon at signal time, so the signal-time healthy check permits the
  # stop and this case still reaches the guard it exists to pin. The beacon is
  # refreshed below once the stop has been issued, which is what a watcher whose
  # TERM handler is deferred actually does: it keeps running its poll loop, and
  # keeps beating, until its current foreground wait returns.
  touch -t 200001010000 "$state/.last-watcher-beat"
  # Backgrounded deliberately. An arm WITHOUT the guard does not exit here: it
  # falls through and blocks in its attached poll, so a foreground run would hang
  # to the harness timeout and report a fixture failure instead of the forbidden
  # attach line this case exists to catch. Waiting for either outcome makes the
  # regression assert the behaviour rather than the hang.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 \
    FM_ARM_RESTART_DEPTH=1 "$WATCH_ARM" --restart > "$out" 2>/dev/null &
  armpid=$!
  # Wait for the stop to actually be issued, then refresh the beacon so the
  # signalled peer reads healthy again at fall-through. Ordering by the peer's own
  # signal receipt makes this caused rather than timed: refreshing earlier would
  # make the signal-time check decline and the case would never reach the guard.
  i=0
  while [ "$i" -lt "$ARM_FAIL_EXIT_POLLS" ] && [ ! -s "$peer_termed" ]; do
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$peer_termed" ] || fail "restart never issued its stop, so the guard was never reached: $(cat "$out")"
  i=0
  while [ "$i" -lt "$ARM_FAIL_EXIT_POLLS" ]; do
    grep -qE 'watcher: (attached|FAILED)' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    touch "$state/.last-watcher-beat"
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$peer" || fail "fixture peer did not survive the restart's stop"
  ! grep -qF 'watcher: attached' "$out" \
    || fail "self-triggered restart attached to the pid it had just TERMed: $(cat "$out")"
  grep -qF "no attach was claimed" "$out" \
    || fail "self-triggered restart did not report the unfinished stop: $(cat "$out")"
  grep -qF "pid=$peer" "$out" \
    || fail "self-triggered restart failure did not name the pid it stopped: $(cat "$out")"
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "self-triggered restart exited zero after failing to stop its watcher: $(cat "$out")"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "a self-triggered restart refuses to attach to the watcher it just terminated"
}

test_restart_never_signals_a_holder_that_is_healthy_at_signal_time() {
  # The third instance of one defect: the arm terminating a watcher that is
  # healthy right now. The first two guards were keyed on having OBSERVED a
  # holder as healthy, so any path reaching the stop without that observation
  # stayed a hole. Here a healthy successor claims the lock in the window between
  # a verification failing and the restart executing, so no observation exists and
  # those guards are silent. The check that closes the class is keyed on CURRENT
  # state: re-read the lock immediately before signalling and refuse if that pid
  # is healthy then.
  local dir state fakebin out successor identity armpid i
  dir=$(make_case restart-healthy-at-signal-time)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  install_identity_probe "$dir"
  sleep 300 &
  successor=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$successor") \
    || fail "could not identify the successor"
  # The lock already names the healthy successor when the restart runs, which is
  # the state that window leaves behind. A restart carrying a decision made before
  # that claim must not act on it.
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$successor" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_ARM_ATTACH_VERIFY=1 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=2 \
    FM_ARM_RESTART_DEPTH=1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  # Wait for a TERMINAL line. The declined line is non-terminal and appears
  # immediately, so breaking on it would assert the follow-through before the arm
  # has had a chance to produce it.
  i=0
  while [ "$i" -lt 300 ]; do
    grep -qE 'watcher: (attached|FAILED)' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$successor" \
    || fail "restart stopped a lock holder that was healthy at the moment of signalling: $(cat "$out")"
  grep -qF 'restart declined' "$out" \
    || fail "restart did not report declining to signal the healthy holder: $(cat "$out")"
  grep -qF "watcher: attached pid=$successor" "$out" \
    || fail "restart declined to signal the healthy holder but then did not follow it: $(cat "$out")"
  kill "$armpid" "$successor" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true
  pass "restart never signals a lock holder that is healthy at the moment of signalling"
}

test_restart_still_replaces_a_wedged_watcher() {
  # The hazard the signal-time check must not create. A watcher that is wedged -
  # process alive and identity-matched, but no longer advancing its liveness
  # beacon - must stay replaceable, because refusing to act on it would strand
  # supervision, a quieter and worse failure than the kill being prevented.
  # fm_watcher_healthy requires the beacon fresh within FM_GUARD_GRACE, and only
  # the watcher touches that beacon, so a wedged holder fails the predicate and is
  # replaced normally. This pins that distinction.
  local dir state fakebin out wedged identity i
  dir=$(make_case restart-replaces-wedged)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  install_identity_probe "$dir"
  sleep 300 &
  wedged=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$wedged") \
    || fail "could not identify the wedged holder"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$wedged" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # A stale beacon is exactly what a wedge looks like from outside.
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=2 \
    FM_ARM_RESTART_DEPTH=1 "$WATCH_ARM" --restart > "$out" 2>/dev/null &
  i=0
  while [ "$i" -lt 200 ]; do
    is_live_non_zombie "$wedged" || break
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$wedged" \
    || fail "restart refused to replace a wedged watcher, stranding supervision: $(cat "$out")"
  ! grep -qF 'restart declined' "$out" \
    || fail "restart treated a wedged watcher as healthy and declined to replace it: $(cat "$out")"
  wait "$wedged" 2>/dev/null || true
  pass "restart still replaces a wedged watcher whose beacon has gone stale"
}

test_restart_declines_when_the_holder_resumes_beating_before_the_stop() {
  # The check-to-stop window. No check placed BEFORE a stop can close it, so this
  # does not test that it is gone: it tests that the outcome changed from
  # "stopped a watcher that had come back" to "declined because it came back".
  # The holder is judged unhealthy on a stale beacon, then resumes beating before
  # the stop is issued. The stop precondition is re-evaluated at that instant and
  # must abort.
  # The window is opened deterministically rather than raced: the arm's own
  # identity probe is made to block until the fixture has refreshed the beacon, so
  # the refresh is ordered strictly between the judgement and the stop.
  local dir state fakebin out holder identity armpid gate i
  dir=$(make_case restart-holder-resumes-beating)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  gate="$dir/probe.gate"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  mkdir -p "$state" "$fakebin" "$dir/noproc"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$holder") \
    || fail "could not identify the holder"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # Stale at judgement time, so the arm decides this holder is replaceable.
  touch -t 200001010000 "$state/.last-watcher-beat"
  # The window has to open BETWEEN the health judgement and the stop. Refreshing
  # any earlier lands inside fm_watcher_healthy, which then simply reports the
  # holder healthy and the earlier check declines - the precondition would never
  # run and this case would pass with or without it.
  # The lock's pid file is read three times on this path: once by the arm, once
  # inside the health judgement, and once by the stop precondition. Firing on the
  # third places the refresh exactly in the window under test.
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\$1" = "$state/.watch.lock/pid" ]; then
  n=0
  [ -f "$dir/cat.count" ] && n=\$(cat "$dir/cat.count" 2>/dev/null)
  n=\$((n + 1))
  printf '%s' "\$n" > "$dir/cat.count"
  if [ "\$n" -eq 3 ]; then
    : > "$gate"
    touch "$state/.last-watcher-beat"
  fi
fi
exec $(command -v cat) "\$@"
SH
  chmod +x "$fakebin/cat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=2 \
    FM_ARM_ATTACH_VERIFY=1 FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_RESTART_DEPTH=1 "$WATCH_ARM" --restart > "$out" 2>/dev/null &
  armpid=$!
  i=0
  while [ "$i" -lt 300 ]; do
    grep -qE 'watcher: (attached|FAILED)' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$gate" ] || fail "fixture never opened the check-to-stop window: $(cat "$out")"
  is_live_non_zombie "$holder" \
    || fail "restart stopped a holder that resumed beating between the check and the stop: $(cat "$out")"
  grep -qF 'restart declined' "$out" \
    || fail "restart did not decline after its stop precondition moved: $(cat "$out")"
  kill "$armpid" "$holder" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "restart declines when its holder resumes beating between the check and the stop"
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

test_arm_signal_replays_watcher_failure_line() {
  # The harness TERMs the arm at a turn boundary; the arm TERMs its watcher,
  # whose EXIT trap prints the step-naming failure line onto the CAPTURED stdout.
  # cleanup_child then deletes that capture, so the line has to be replayed
  # first or the exact teardown this change exists to make diagnosable stays
  # silent. The replay is filtered to `watcher: FAILED` lines because the arm's
  # stdout is what the adapters and bin/fm-claude-stop-autoarm.sh classify: an
  # unfiltered replay would surface a wake reason line for a cycle that is being
  # torn down on purpose. Both halves are asserted here, the second against a
  # wake line seeded into the capture the arm actually owns.
  local dir state fakebin armout armerr armpid capture status i candidate
  dir=$(make_case arm-signal-stdout-replay)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  armerr="$dir/arm.err"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" 2> "$armerr" &
  armpid=$!
  # Ordered handshake: the started line prints only after the watcher is live and
  # confirmed, so the TERM is caused by that state rather than timed against it.
  i=0
  while [ "$i" -lt 120 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start a watcher before the signal-replay check"
  capture=
  for candidate in "$state"/.watch-arm-output.*; do
    [ -e "$candidate" ] || continue
    capture=$candidate
    break
  done
  [ -n "$capture" ] || fail "arm left no stdout capture to replay from"
  printf 'check: %s/task.check.sh: merged: https://example.test/pr/7\n' "$state" >> "$capture"
  kill -TERM "$armpid" 2>/dev/null || fail "could not TERM the arm"
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -eq 143 ] || fail "arm did not exit with TERM status (got $status): $(cat "$armerr")"
  grep -qE 'watcher: FAILED - watcher cycle exited [0-9]+ during [a-z][a-z0-9:._-]* after SIGTERM' "$armerr" \
    || fail "interrupted arm dropped the watcher's own failure line: out=$(cat "$armout") err=$(cat "$armerr")"
  ! grep -qF 'merged: https://example.test/pr/7' "$armerr" \
    || fail "interrupted arm replayed a non-FAILED watcher stdout line: $(cat "$armerr")"
  ! grep -qF 'merged: https://example.test/pr/7' "$armout" \
    || fail "interrupted arm leaked a non-FAILED watcher stdout line onto its own stdout: $(cat "$armout")"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "signal cleanup left the arm's stdout capture behind"
  pass "an interrupted arm replays only the watcher's failure line from captured stdout"
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

seed_watcher_lock_for_pid() {  # <state> <dir> <pid>
  local state=$1 dir=$2 pid=$3 identity
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not identify seeded lock holder $pid"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
}

# An ordered handshake for the attach fixtures, in the same spirit as the
# TERM-resistant peer's readiness file: the arm resolves a lock holder's identity
# through fm_pid_identity before it can call that holder healthy, so a recording
# `ps` shim on the case's fakebin marks the exact moment the arm has read the
# lock. Timing the fixture against a sleep budget instead raced arm startup and
# measured the fixture, not the contract. FM_PROC_ROOT_OVERRIDE points the
# library at an empty tree so the portable ps identity is taken on a host with a
# real /proc too; the caller scopes it with `local -x`.
install_identity_probe() {  # <dir>
  local dir=$1 real_ps
  real_ps=$(command -v ps) || fail "no ps on PATH for the attach identity probe"
  mkdir -p "$dir/noproc"
  : > "$dir/ps-probe.log"
  # The probe row is written AFTER the real ps has answered, never before it.
  # Logging first only proves the arm was about to look; the test then kills the
  # holder while that very ps is still running, fm_pid_identity reads an empty
  # answer, and the arm skips the attach path the case exists to exercise.
  cat > "$dir/fakebin/ps" <<SH
#!/usr/bin/env bash
ps_out=\$("$real_ps" "\$@")
ps_rc=\$?
printf '%s\n' "\$*" >> "$dir/ps-probe.log"
[ -z "\$ps_out" ] || printf '%s\n' "\$ps_out"
exit "\$ps_rc"
SH
  chmod +x "$dir/fakebin/ps"
}

wait_for_identity_probe() {  # <dir> <pid> [tries]
  local dir=$1 pid=$2 tries=${3:-400} i=0
  while [ "$i" -lt "$tries" ]; do
    grep -qF -- "-p $pid " "$dir/ps-probe.log" 2>/dev/null && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# The same handshake, for a case that must know the arm has moved PAST its entry
# health check and into the verification window. The entry check resolves the
# holder's identity once and every in-window sample resolves it again, so a
# second probe row is proof the window is open. Mutating the lock on the first
# row alone would sometimes land before the entry check finished and send the arm
# down the start path, testing the fixture instead of the contract.
wait_for_identity_probe_count() {  # <dir> <pid> <count> [tries]
  local dir=$1 pid=$2 want=$3 tries=${4:-400} i=0 n
  while [ "$i" -lt "$tries" ]; do
    n=$(grep -cF -- "-p $pid " "$dir/ps-probe.log" 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -ge "$want" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# Two live processes with the SAME fm_pid_identity, so handing the watcher lock
# from one to the other is a single atomic rename of the lock's pid file. Writing
# pid and pid-identity separately would leave a window in which the lock names a
# pid whose identity does not match, and a poll landing inside it would read a
# half-written handover as a dead watcher. The portable ps identity is lstart
# plus command, so twins started within one second qualify; a straddled second is
# retried rather than tolerated.
TWIN_A=
TWIN_B=
spawn_identity_twins() {  # <state>
  local state=$1 attempt=0 a b id_a id_b
  TWIN_A=
  TWIN_B=
  while [ "$attempt" -lt 20 ]; do
    sleep 300 &
    a=$!
    sleep 300 &
    b=$!
    id_a=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$a" 2>/dev/null || true)
    id_b=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$b" 2>/dev/null || true)
    if [ -n "$id_a" ] && [ "$id_a" = "$id_b" ]; then
      TWIN_A=$a
      TWIN_B=$b
      return 0
    fi
    kill "$a" "$b" 2>/dev/null || true
    wait "$a" 2>/dev/null || true
    wait "$b" 2>/dev/null || true
    attempt=$((attempt + 1))
  done
  return 1
}

test_arm_retargets_to_a_healthy_lock_successor() {
  # Issue #1383's duplicate-arm shape: this arm is verifying W1 when a peer arm's
  # W2 wins the singleton and W1 stands down. W2 passes the very gate the arm uses
  # to call an attach healthy, so a lock move onto it is an ATTACH to W2, never a
  # failed attach - treating it as one made the arm exec --restart, whose first
  # act is TERM on the current lock pid, killing a watcher that was fine and
  # making its owning arm report a failure it had no evidence for.
  local dir state fakebin armout armpid i
  dir=$(make_case arm-attach-retarget)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  install_identity_probe "$dir"
  spawn_identity_twins "$state" || fail "could not spawn two lock holders sharing one identity"
  seed_watcher_lock_for_pid "$state" "$dir" "$TWIN_A"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_ARM_ATTACH_VERIFY=6 FM_ARM_CONFIRM_TIMEOUT=5 FM_ARM_ATTACH_POLL=0.1 \
    "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_identity_probe "$dir" "$TWIN_A" || fail "arm never read the seeded lock holder"
  printf '%s\n' "$TWIN_B" > "$state/.watch.lock/pid.next"
  mv -f "$state/.watch.lock/pid.next" "$state/.watch.lock/pid"
  i=0
  while [ "$i" -lt 200 ]; do
    grep -qF "watcher: attached pid=$TWIN_B" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$TWIN_B" "$armout" \
    || fail "arm did not retarget onto the healthy lock successor: $(cat "$armout")"
  # The retargeted attach must be VERIFIED, not claimed off the single read that
  # observed the lock move. Without this the case passes against any arm that
  # simply never restarts, and stops discriminating at all.
  grep -qE "watcher: attached pid=$TWIN_B \(beacon [0-9]+s, verified [0-9]+s" "$armout" \
    || fail "arm reported the retargeted attach without verifying it: $(cat "$armout")"
  # Behavioural, not textual. `verified Ns` is a constant in report_attached, so
  # grepping it proves nothing on its own. An arm that really verifies is still
  # inside the window when the lock moves, so it retargets and announces TWIN_B
  # only. An arm that returns from verification immediately announces the holder
  # it entered on, TWIN_A, before ever seeing the move.
  ! grep -qF "watcher: attached pid=$TWIN_A" "$armout" \
    || fail "arm announced an attach to the pre-move holder, so it did not verify inside the window: $(cat "$armout")"
  is_live_non_zombie "$TWIN_B" || fail "arm killed the verified healthy successor it should have attached to"
  ! grep -qF 'watcher: restarting after a failed attach' "$armout" \
    || fail "arm restarted over a verified healthy successor: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy successor: $(cat "$armout")"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy successor"
  is_live_non_zombie "$armpid" || fail "arm exited while the successor it attached to was still healthy"
  kill "$armpid" "$TWIN_A" "$TWIN_B" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$TWIN_A" 2>/dev/null || true
  wait "$TWIN_B" 2>/dev/null || true
  pass "arm retargets onto a healthy lock successor instead of restarting over it"
}

test_watch_lock_claim_publishes_the_watcher_identity() {
  # The claim IS the publication. A reader reaches the watcher lock only through
  # the symlink fm_lock_try_acquire creates last, so a lock that is visible at all
  # is a lock whose identity records are already visible with it. No amount of
  # care by the caller afterwards can provide that: any later write leaves a
  # stretch in which the lock names a live pid and nothing verifiable, and no
  # reader can tell that apart from a lock left behind by a dead one.
  local dir state fakebin holder lock_pid lock_home lock_path lock_identity live_identity i
  dir=$(make_case watch-lock-claim-publishes)
  state="$dir/state"
  fakebin="$dir/fakebin"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  install_identity_probe "$dir"
  # Claim the lock through the production library exactly as bin/fm-watch.sh does,
  # then stay alive, so the published identity is checked against a live process
  # rather than against a corpse.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; FM_LOCK_WATCHER_PATH="$2"; fm_lock_try_acquire "$3/.watch.lock" || exit 1
     printf claimed > "$4"; sleep 30' \
    _ "$LIB" "$WATCH" "$state" "$dir/claimed" &
  holder=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -s "$dir/claimed" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/claimed" ] || fail "the library never claimed the watcher lock"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  lock_home=$(cat "$state/.watch.lock/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$state/.watch.lock/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$state/.watch.lock/pid-identity" 2>/dev/null || true)
  [ "$lock_pid" = "$holder" ] || fail "the claim recorded pid '$lock_pid', not the claiming process $holder"
  [ "$lock_home" = "$dir" ] || fail "the claim did not publish this home with the lock: '$lock_home'"
  [ "$lock_path" = "$WATCH" ] || fail "the claim did not publish the watcher path with the lock: '$lock_path'"
  [ -n "$lock_identity" ] || fail "the claim published no watcher identity, so a live holder is indistinguishable from a stale one"
  live_identity=$(FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$holder") \
    || fail "could not identify the live lock holder"
  [ "$lock_identity" = "$live_identity" ] \
    || fail "the published identity does not match the live holder: '$lock_identity' vs '$live_identity'"
  # The records are not merely present: they satisfy the gate every reader uses.
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir" \
    || fail "a freshly claimed watcher lock did not read as healthy"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "claiming the watcher lock publishes the identity that makes it verifiable"
}

test_watcher_identity_is_published_under_lock_contention() {
  # The same guarantee end to end, against the contention that used to set the
  # width of the gap. The watcher's own start-up work between claiming the lock and
  # describing itself included two unbounded waits on the wake-queue lock, so the
  # stretch in which its lock named nothing verifiable was as long as whatever else
  # held that lock - and bin/fm-wake-drain.sh is entitled to hold it for ten
  # seconds. Publishing with the claim severs that coupling entirely: this holds
  # the same lock and asserts the watcher is describable the instant it is visible.
  local dir state fakebin queue_holder watcher lock_pid lock_identity i
  dir=$(make_case watch-lock-publish-under-contention)
  state="$dir/state"
  fakebin="$dir/fakebin"
  FM_HOME="$dir" bash -c \
    '. "$1"; fm_lock_acquire_wait "$2/.wake-queue.lock" || exit 1
     printf held > "$3"; sleep "$4"; fm_lock_release "$2/.wake-queue.lock"' \
    _ "$LIB" "$state" "$dir/queue-held" 4 &
  queue_holder=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -s "$dir/queue-held" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/queue-held" ] || fail "the fixture never took the wake-queue lock"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  # Sample far faster than the contention lasts, and read the identity in the same
  # breath as the pid, so the assertion is about the first observable state of the
  # lock rather than about some later settled one.
  lock_pid=
  lock_identity=
  i=0
  while [ "$i" -lt 400 ]; do
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ]; then
      lock_identity=$(cat "$state/.watch.lock/pid-identity" 2>/dev/null || true)
      break
    fi
    sleep 0.02
    i=$((i + 1))
  done
  [ -n "$lock_pid" ] || fail "the watcher never claimed its lock: $(cat "$dir/watch.err")"
  # Proof the sample landed inside the contention rather than after it cleared.
  [ -e "$state/.wake-queue.lock" ] \
    || fail "the wake-queue lock was already released, so the sample proves nothing"
  [ -n "$lock_identity" ] \
    || fail "the watcher lock was visible with no identity while another process held the wake-queue lock"
  kill "$watcher" "$queue_holder" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  wait "$queue_holder" 2>/dev/null || true
  pass "a contended watcher start publishes its identity with its lock, not after it"
}

test_arm_never_restarts_over_a_healthy_lock_holder() {
  # F1. The retarget budget is a bound on how long verification will chase a
  # moving lock. It is NOT a licence to kill whoever holds the lock when it runs
  # out. On the budget+1-th move the arm used to return a failed attach while the
  # lock named a pid that had just passed healthy_watcher, and a failed attach's
  # only recovery is --restart, whose first act is TERM on that exact pid. The
  # arm must abandon the attach instead, and every holder must survive.
  local dir state fakebin armout armpid i n moved
  dir=$(make_case arm-retarget-exhausted)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  install_identity_probe "$dir"
  spawn_identity_twins "$state" || fail "could not spawn two lock holders sharing one identity"
  seed_watcher_lock_for_pid "$state" "$dir" "$TWIN_A"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_ARM_ATTACH_VERIFY=2 FM_ARM_CONFIRM_TIMEOUT=5 FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_ATTACH_RETARGET_MAX=1 FM_ARM_RESTART_MAX=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_identity_probe "$dir" "$TWIN_A" || fail "arm never read the seeded lock holder"
  # One move more than the budget allows, alternating between two live holders
  # that both pass the health gate, so exhaustion is reached with the lock naming
  # a genuinely healthy pid rather than a dying one.
  moved=0
  for n in "$TWIN_B" "$TWIN_A" "$TWIN_B"; do
    printf '%s\n' "$n" > "$state/.watch.lock/pid.next"
    mv -f "$state/.watch.lock/pid.next" "$state/.watch.lock/pid"
    moved=$((moved + 1))
    sleep 0.3
  done
  [ "$moved" -eq 3 ] || fail "fixture did not move the lock past the retarget budget"
  i=0
  while [ "$i" -lt 200 ]; do
    grep -qE 'watcher: (attach abandoned|restarting after a failed attach)' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  ! grep -qF 'watcher: restarting after a failed attach' "$armout" \
    || fail "arm restarted over a lock a healthy watcher was holding: $(cat "$armout")"
  grep -qF 'watcher: attach abandoned' "$armout" \
    || fail "arm did not abandon the attach after exhausting its retarget budget: $(cat "$armout")"
  grep -qF 'a healthy watcher holds the lock' "$armout" \
    || fail "arm did not name the healthy holder as the reason it declined to restart: $(cat "$armout")"
  is_live_non_zombie "$TWIN_A" || fail "arm killed a healthy lock holder after exhausting its retarget budget"
  is_live_non_zombie "$TWIN_B" || fail "arm killed the healthy holder that owned the lock at exhaustion"
  kill "$armpid" "$TWIN_A" "$TWIN_B" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$TWIN_A" 2>/dev/null || true
  wait "$TWIN_B" 2>/dev/null || true
  pass "arm abandons an exhausted retarget instead of restarting over the healthy holder"
}

test_arm_never_stops_a_lock_holder_it_cannot_verify() {
  # The safety property the deleted settling tolerance used to carry. With the
  # identity published at claim time no watcher can produce an unverifiable lock,
  # so this state is unreachable from bin/fm-watch.sh - but a lock the arm cannot
  # verify must still never become a lock the arm terminates, because the arm has
  # no evidence about what that process is. --restart declines to signal a holder
  # whose lock does not identify it as this home's watcher, and only says so.
  local dir state fakebin out holder armpid i
  dir=$(make_case arm-unverifiable-holder)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  install_identity_probe "$dir"
  sleep 300 &
  holder=$!
  seed_watcher_lock_for_pid "$state" "$dir" "$holder"
  # Strip the identity, leaving a live pid the arm has no way to vouch for.
  rm -f "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_RESTART_DEPTH=1 \
    "$WATCH_ARM" --restart > "$out" 2>/dev/null &
  armpid=$!
  i=0
  while [ "$i" -lt "$ARM_FAIL_EXIT_POLLS" ]; do
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$holder" \
    || fail "restart terminated a lock holder it could not identify as this home's watcher: $(cat "$out")"
  ! grep -qF "watcher: attached pid=$holder" "$out" \
    || fail "arm claimed a verified attach to a holder with no published identity: $(cat "$out")"
  kill "$armpid" "$holder" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "arm leaves a lock holder it cannot verify running instead of stopping it"
}

test_attached_arm_bounds_repeated_replacement_verification_failures() {
  # An arm attached to a healthy watcher re-evaluates a replacement candidate
  # that fails verification, on the ordinary cadence. Each attempt starts a fresh
  # verification with a fresh retarget budget, so a lock held in a
  # flapping-but-sampled-healthy state can keep the arm re-attempting forever and
  # never reach a terminal result. That is the same quiet failure as a cycle that
  # exits without saying why, which is what this change exists to remove.
  # The flap is the realistic one: BOTH holders are live, identity-matched and
  # beaconing, so every sample reads healthy and each attempt fails only by
  # exhausting its retarget budget. Nothing here is racing a death.
  local dir state fakebin armout armpid i status
  dir=$(make_case attached-replacement-bound)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
  install_identity_probe "$dir"
  spawn_identity_twins "$state" || fail "could not spawn two lock holders sharing one identity"
  seed_watcher_lock_for_pid "$state" "$dir" "$TWIN_A"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_ARM_ATTACH_VERIFY=1 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 \
    FM_ARM_ATTACH_RETARGET_MAX=1 FM_ARM_ATTACH_REPLACEMENT_MAX=3 FM_ARM_RESTART_MAX=0 \
    "$WATCH_ARM" > "$armout" &
  armpid=$!
  # The arm must first ATTACH cleanly, so what follows exercises the in-loop
  # replacement branch rather than the entry attach.
  i=0
  while [ "$i" -lt 200 ]; do
    grep -qF "watcher: attached pid=$TWIN_A" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$TWIN_A" "$armout" \
    || fail "arm never attached to the seeded holder, so the replacement branch was never reached: $(cat "$armout")"
  # Now flap the lock between the two live twins faster than one verification
  # window can complete. Every candidate is healthy when selected and healthy at
  # every later sample, so each attempt ends by exhausting its retarget budget
  # rather than by observing anything dead.
  i=0
  while [ "$i" -lt 600 ]; do
    is_live_non_zombie "$armpid" || break
    grep -qF 'consecutive replacement watchers failed verification' "$armout" 2>/dev/null && break
    printf '%s\n' "$TWIN_B" > "$state/.watch.lock/pid.next"
    mv -f "$state/.watch.lock/pid.next" "$state/.watch.lock/pid"
    touch "$state/.last-watcher-beat"
    sleep 0.1
    printf '%s\n' "$TWIN_A" > "$state/.watch.lock/pid.next"
    mv -f "$state/.watch.lock/pid.next" "$state/.watch.lock/pid"
    touch "$state/.last-watcher-beat"
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'consecutive replacement watchers failed verification' "$armout" \
    || fail "attached arm never bounded its replacement retries: $(cat "$armout")"
  is_live_non_zombie "$TWIN_A" || fail "attached arm killed a healthy twin while bounding its retries"
  is_live_non_zombie "$TWIN_B" || fail "attached arm killed a healthy twin while bounding its retries"
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "attached arm returned success after exhausting its replacement retries (status $status)"
  kill "$armpid" "$TWIN_A" "$TWIN_B" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$TWIN_A" 2>/dev/null || true
  wait "$TWIN_B" 2>/dev/null || true
  pass "attached arm bounds repeated replacement verification failures into a terminal result"
}

# The pid of the watcher a cycle actually STARTED, read from the arm layer's own
# lifecycle ledger. It answers "did a fresh watcher run" for a cycle that ended
# too fast for the arm to print its started line.
started_watcher_pid_from_ledger() {  # <state>
  [ -f "$1/.watch-cycle-exits.log" ] || return 0
  awk -F'\t' '
    $3 == "origin=started" {
      for (i = 1; i <= NF; i += 1) {
        if ($i ~ /^watcher_pid=/) pid = substr($i, 13)
      }
    }
    END { if (pid != "" && pid != "none") print pid }
  ' "$1/.watch-cycle-exits.log" 2>/dev/null
}

test_arm_refuses_to_attach_to_a_dying_watcher() {
  # A holder that is live with a fresh beacon at the instant the arm reads it,
  # and gone moments later, is exactly the reported race: one healthy read proves
  # the target existed RECENTLY, not that it is alive now. The arm must never
  # announce that target as an attached healthy cycle. With a restart budget it
  # restarts and ends up owning a genuinely live watcher; without one it says the
  # attach was abandoned and starts a fresh watcher instead.
  # The holder dies only AFTER the arm has demonstrably read the lock, so the
  # ordering is caused rather than timed: a sleep budget racing arm startup would
  # let a loaded machine skip the attach path entirely and fail on the fixture.
  local row dir state fakebin armout holder armpid lock_pid started_pid settled i
  for row in restart no-restart; do
    dir=$(make_case "arm-dying-attach-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    local -x FM_PROC_ROOT_OVERRIDE="$dir/noproc"
    install_identity_probe "$dir"
    sleep 300 &
    holder=$!
    seed_watcher_lock_for_pid "$state" "$dir" "$holder"
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
      FM_HEARTBEAT=999999 FM_ARM_ATTACH_VERIFY=6 FM_ARM_CONFIRM_TIMEOUT=5 FM_ARM_ATTACH_POLL=0.1 \
      FM_ARM_RESTART_MAX=$([ "$row" = restart ] && echo 1 || echo 0) \
      "$WATCH_ARM" > "$armout" &
    armpid=$!
    wait_for_identity_probe "$dir" "$holder" || fail "arm ($row) never read the seeded lock holder"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    # Clearing the dead holder's lock publishes durable recovery evidence, so the
    # fresh watcher may deliver `check: rearm-resurface` and end its cycle before
    # the arm ever prints a started line. Both endings prove the same thing this
    # case is about - a genuinely new watcher process ran instead of the dying
    # holder being claimed - so wait for whichever of them the timing produces.
    i=0
    started_pid=
    while [ "$i" -lt 200 ]; do
      started_pid=$(sed -n 's/.*watcher: started pid=\([0-9][0-9]*\).*/\1/p' "$armout" 2>/dev/null | head -1)
      [ -n "$started_pid" ] && break
      started_pid=$(started_watcher_pid_from_ledger "$state")
      [ -n "$started_pid" ] && break
      sleep 0.1
      i=$((i + 1))
    done
    ! grep -qF "watcher: attached pid=$holder" "$armout" \
      || fail "arm ($row) reported a healthy attach to a watcher that was already dying: $(cat "$armout")"
    if [ "$row" = restart ]; then
      grep -qF 'watcher: restarting after a failed attach' "$armout" \
        || fail "arm ($row) did not restart after the failed attach: $(cat "$armout")"
    else
      grep -qF 'watcher: attach abandoned' "$armout" \
        || fail "arm ($row) did not report the abandoned attach: $(cat "$armout")"
    fi
    [ -n "$started_pid" ] \
      || fail "arm ($row) did not restore supervision with a fresh watcher: $(cat "$armout")"
    [ "$started_pid" != "$holder" ] \
      || fail "arm ($row) restored supervision onto the dead holder itself: $(cat "$armout")"
    # The fresh watcher and the arm's report of it do not settle at the same
    # instant, so this samples a SETTLED state rather than whichever moment the
    # ledger row happened to land in. A cycle that has already ended on a
    # delivered wake still answers a bare `kill -0` while it is a zombie, and its
    # lock is released before the arm writes that wake line - reading either fact
    # on its own is a coin flip, not an assertion. Both endings prove the same
    # thing: the fresh watcher is confirmably live, owns the lock, and is named by
    # the started line, or the arm published the wake its cycle delivered.
    i=0
    settled=
    while [ "$i" -lt 200 ]; do
      lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
      if is_live_non_zombie "$started_pid" && [ "$lock_pid" = "$started_pid" ] \
        && grep -qF "watcher: started pid=$started_pid" "$armout" 2>/dev/null; then
        settled=live
        break
      fi
      if grep -qE '^(signal:|stale:|check:|heartbeat)' "$armout" 2>/dev/null; then
        settled=delivered
        break
      fi
      sleep 0.1
      i=$((i + 1))
    done
    [ -n "$settled" ] \
      || fail "arm ($row) fresh watcher neither confirmably held the lock nor delivered a wake (lock '$lock_pid'): $(cat "$armout")"
    # Lock ownership must be proven on BOTH endings, or the weaker one silently
    # retires the assertion. The live ending checks the lock directly above. The
    # delivered ending checks the watcher's own terminal delivery record, which
    # the cycle publishes under its pid while it still holds the lock and before
    # it releases it - so a matching pid is proof the FRESH watcher owned the
    # lock and ran a full cycle, not merely that the arm printed a wake line.
    if [ "$settled" = delivered ]; then
      i=0
      while [ "$i" -lt 200 ]; do
        cut -f1 "$state/.watch-deliveries.log" 2>/dev/null | grep -qxF "$started_pid" && break
        sleep 0.1
        i=$((i + 1))
      done
      cut -f1 "$state/.watch-deliveries.log" 2>/dev/null | grep -qxF "$started_pid" \
        || fail "arm ($row) published a wake with no delivery record proving pid=$started_pid held the lock: $(cat "$state/.watch-deliveries.log" 2>/dev/null)"
    fi
    kill "$armpid" "$started_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm refuses to attach to a dying watcher and restarts supervision instead"
}

test_nonzero_watcher_exit_reports_an_actionable_reason() {
  # "exited 1 without an actionable reason" is undiagnosable by construction.
  # Every non-zero cycle must name the step it died in, the signal when one
  # caused it, and whatever the cycle wrote to stderr.
  local dir state fakebin armout armerr armpid watcher_pid status i live
  dir=$(make_case watcher-exit-reason-signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "watcher did not start before the exit-reason check"
  kill -TERM "$watcher_pid" 2>/dev/null || fail "could not signal the watcher"
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated watcher cycle did not fail the arm (status $status)"
  grep -qE 'watcher cycle exited [0-9]+ during [a-z][a-z0-9:._-]* after SIGTERM' "$armout" \
    || fail "non-zero watcher exit did not name its step and signal: $(cat "$armout")"

  # A pre-lock refusal writes its explanation to stderr; the arm must name the
  # step on stdout and replay that stderr rather than swallowing it.
  dir=$(make_case watcher-exit-reason-stderr)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  armerr="$dir/arm.err"
  sleep 300 &
  live=$!
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 \
    "$WATCH_ARM" > "$armout" 2> "$armerr" || status=$?
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "arm exited zero for a watcher that refused to start"
  grep -qF 'watcher cycle exited 1 during lock-acquire' "$armout" \
    || fail "refused watcher exit did not name the lock-acquire step: $(cat "$armout")"
  grep -qF 'heartbeat is stale' "$armerr" \
    || fail "arm swallowed the watcher's own stderr explanation: $(cat "$armerr")"
  ! ls "$state"/.watch-arm-stderr.* >/dev/null 2>&1 || fail "arm left its stderr capture behind"
  pass "a non-zero watcher exit reports its step, signal, and stderr"
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
test_pid_identity_is_locale_invariant
test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse
test_msys_pid_identity_uses_proc
test_stale_watch_lock_reclaimed
test_stale_watch_reclaim_publishes_before_clear
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
test_watch_restart_attaches_to_healthy_peer
test_self_triggered_restart_refuses_to_attach_to_the_pid_it_termed
test_restart_never_signals_a_holder_that_is_healthy_at_signal_time
test_restart_still_replaces_a_wedged_watcher
test_restart_declines_when_the_holder_resumes_beating_before_the_stop
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_signal_replays_watcher_failure_line
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_arm_refuses_to_attach_to_a_dying_watcher
test_arm_retargets_to_a_healthy_lock_successor
test_arm_never_restarts_over_a_healthy_lock_holder
test_watch_lock_claim_publishes_the_watcher_identity
test_watcher_identity_is_published_under_lock_contention
test_arm_never_stops_a_lock_holder_it_cannot_verify
test_attached_arm_bounds_repeated_replacement_verification_failures
test_nonzero_watcher_exit_reports_an_actionable_reason
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
