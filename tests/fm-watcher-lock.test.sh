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

# Execute the actual disposable-checkout guard before any watcher can start.
lab="$TMP_ROOT/marked-lab"
foreign_state="$TMP_ROOT/foreign-state"
checkout="$TMP_ROOT/.no-mistakes/worktrees/guard/bin"
mkdir -p "$lab" "$foreign_state" "$checkout"
. "$ROOT/bin/fm-gate-refuse-lib.sh"
fm_gate_lab_mark "$lab" || fail "could not mark the watcher lab"
cp "$WATCH_ARM" "$ROOT/bin/fm-gate-refuse-lib.sh" "$checkout/"
if env -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE FM_HOME="$lab" STATE="$foreign_state" \
  bash "$checkout/fm-watch-arm.sh" > "$TMP_ROOT/lab-guard.out" 2>&1; then
  fail "disposable watcher accepted an inherited state outside its lab"
fi
grep -q 'refusing to arm from a disposable validation checkout' "$TMP_ROOT/lab-guard.out" \
  || fail "disposable watcher did not reject the relocated state"
[ ! -e "$foreign_state/.watch.lock" ] || fail "disposable watcher touched outside state"
pass "disposable watcher refuses inherited state outside its marked lab"

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

test_wait_deadline_reaps_a_stopped_child() {
  # A stopped TERM-resistant child cannot finish graceful cleanup. The helper waited
  # forever after its nominal deadline. An outer process-group deadline keeps
  # this regression finite even if that bug returns.
  python3 - "$ROOT/tests/wake-helpers.sh" <<'PY' || fail "bounded child cleanup regression"
import os
import signal
import subprocess
import sys

script = r'''
. "$1"
bash -c 'trap "" TERM; kill -STOP "$$"; exec sleep 300' &
pid=$!
for i in $(seq 1 100); do
  state=$(ps -p "$pid" -o stat=)
  case "$state" in *T*) break ;; esac
  sleep 0.01
done
case "$state" in *T*) ;; *) kill -KILL "$pid"; exit 23 ;; esac
wait_for_exit "$pid" 2
rc=$?
[ "$rc" = 124 ] || exit 21
! kill -0 "$pid" 2>/dev/null || exit 22
'''
p = subprocess.Popen([os.environ.get("BASH", "bash"), "-c", script, "_", sys.argv[1]],
                     start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    out, err = p.communicate(timeout=15)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.communicate()
    raise SystemExit("wait_for_exit hung after its deadline on a stopped child")
if p.returncode or "survived TERM; sending KILL" not in err:
    raise SystemExit(f"cleanup rc={p.returncode}, stdout={out}, stderr={err}")
PY
  pass "wait deadline diagnoses and reaps a stopped test child without hanging"
}

# Preserve the real watcher's trap diagnostics when testing its termination.
# A termination defect should fail this case promptly, not occupy a CI runner
# until the whole job times out and hides every following test.
stop_seed_watcher() {  # <owned-pid> <output-path>
  local pid=$1 out=$2 status=0
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 100 || status=$?
  if [ "$status" -eq 124 ]; then
    cat "$out" >&2
    fail "seed watcher survived TERM; see bounded wait/process/trap evidence above"
  fi
  if grep -E 'unexpected EOF|syntax error' "$out" >/dev/null; then
    cat "$out" >&2
    fail "seed watcher emitted a shell parser error during termination"
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

test_live_stalled_watch_lock_is_replaced_past_hard_bound() {
  # A live holder whose beacon is stale past the ordinary grace is refused, but
  # a beacon stale past the hard bound evicts that holder (identity-verified
  # TERM) and the arm starts in its place - the deadlock where every re-arm
  # died against a live-but-stalled watcher while nothing polled the home.
  local dir state fakebin out err status holder identity pid i lock_pid
  dir=$(make_case live-stalled-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$holder") || fail "could not identify the fake holder"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # Beacon decades old: past the grace, but a bound beyond it -> still refused.
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_WATCHER_STALL_BOUND=9999999999 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher replaced a holder whose beacon was under the hard bound"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "under-bound stale holder lost its refusal"
  is_live_non_zombie "$holder" || fail "under-bound stale holder was signalled"
  # Same holder and beacon, a bound it is past -> evicted and replaced.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_WATCHER_STALL_BOUND=3 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" &
  pid=$!
  i=0
  lock_pid=
  while [ "$i" -lt 100 ]; do
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$lock_pid" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" || fail "replacement watcher did not stay alive: $(cat "$err")"
  [ "$lock_pid" = "$pid" ] || fail "replacement watcher did not take the lock (holder=$lock_pid)"
  is_live_non_zombie "$holder" && fail "stalled holder survived the eviction"
  # The lock pid is written inside fm_lock_try_acquire; the replacement message
  # is echoed just after, so poll for the message rather than grep once and race
  # the acquire/echo gap.
  i=0
  while [ "$i" -lt 100 ]; do
    grep -E "^watcher: replaced stalled pid $holder \(beacon [0-9]+s past hard bound 3s\)\$" "$out" >/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -E "^watcher: replaced stalled pid $holder \(beacon [0-9]+s past hard bound 3s\)\$" "$out" >/dev/null \
    || fail "watcher did not report the replacement: $(cat "$out" "$err")"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "live watcher lock with a beacon past the hard bound is replaced, under it is still refused"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line pid identity blind
  dir=$(make_case guard)
  # The repair line the cases below assert is the CLAUDE one, so detect_own has to
  # answer claude. A marker alone no longer pins that: a structural ancestor of a
  # different harness outranks it, so the harness this suite was launched from
  # would otherwise choose the wording. Blind the ancestry walk as well; every
  # other ps query (watcher liveness below) still reaches the real ps.
  blind=$(fm_fakebin "$dir/blind")
  fm_fake_blind_ancestry "$blind"
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  PATH="$blind:$PATH" CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
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
  PATH="$blind:$PATH" CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
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

# Start a process that claims each given link lock, then SIGKILL it so every
# claim is left behind with a dead owner - an acquirer TERMed mid-steal.
leave_dead_link_locks() {  # <state> <lock>...
  local state=$1 holder i last
  shift
  last=${!#}
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    shift
    for lock do fm_lock_try_create "$lock" || exit 7; done
    exec sleep 30
  ' _ "$LIB" "$@" >/dev/null 2>&1 &
  holder=$!
  # A loaded serial shard can stall the holder's startup past a second; allow
  # the same ~5s as this file's other child-startup waits.
  i=0
  while [ "$i" -lt 250 ] && [ ! -s "$last/pid" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$last/pid" ] || fail "dead link-lock owner did not publish its pid"
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

test_lock_reclaims_dead_steal_owner_without_nested_markers() {
  local dir state lockdir fakebin lnlog rc
  dir=$(make_case lock-dead-steal-owner)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  fakebin="$dir/fakebin"
  lnlog="$dir/ln.log"
  mkdir "$lockdir"
  printf '%s\n' "$(dead_pid)" > "$lockdir/pid"
  leave_dead_link_locks "$state" "$lockdir.steal"
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
last=
for arg do last=$arg; done
printf '%s\n' "$last" >> "$FM_TEST_LN_LOG"
exec /bin/ln "$@"
SH
  chmod +x "$fakebin/ln"
  : > "$lnlog"

  rc=0
  PATH="$fakebin:$PATH" FM_TEST_LN_LOG="$lnlog" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 8
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer could not reclaim dead steal owner (rc=$rc)"
  ! grep -q '\.steal\.steal$' "$lnlog" \
    || fail "reclaiming a dead steal owner created a nested steal marker: $(tr '\n' ' ' < "$lnlog")"
  [ ! -e "$lockdir.steal" ] && [ ! -L "$lockdir.steal" ] \
    || fail "dead steal mutex remained linked after successful reclaim"
  pass "dead steal owner is reclaimed once without a nested steal marker"
}

test_lock_recovers_dead_nested_steal_chain() {
  local dir state lockdir rc marker
  dir=$(make_case lock-dead-nested-steal-chain)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  printf '%s\n' "$(dead_pid)" > "$lockdir/pid"
  leave_dead_link_locks "$state" "$lockdir.steal" "$lockdir.steal.steal"

  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 8
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -eq 0 ] || fail "dead nested steal chain kept the lock unrecoverable (rc=$rc)"
  for marker in "$lockdir.steal" "$lockdir.steal.steal"; do
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || fail "dead steal marker remained: $marker"
  done
  pass "dead nested steal chain from an interrupted reclaim is recovered"
}

test_lock_reclaims_self_held_steal_mutex() {
  # A TERM that lands while this process holds the steal mutex runs the EXIT
  # path, which re-acquires the same dead-owner lock. The abandoned steal hold
  # is this process's own and must not wedge that exit path.
  local dir state lockdir rc
  dir=$(make_case lock-self-held-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  printf '%s\n' "$(dead_pid)" > "$lockdir/pid"

  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_create "$2.steal" || exit 7
    fm_lock_try_acquire "$2" || exit 8
    [ "$(cat "$2/pid" 2>/dev/null)" = "${BASHPID:-$$}" ] || exit 9
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -eq 0 ] || fail "self-held steal mutex blocked reclaiming a dead-owner lock (rc=$rc)"
  [ ! -e "$lockdir.steal" ] && [ ! -L "$lockdir.steal" ] \
    || fail "self-held steal mutex remained linked after reclaim"
  pass "a steal mutex abandoned by this process does not block its own reclaim"
}

test_lock_resumes_own_interrupted_steal_reap() {
  # A TERM that lands after this process renamed a dead steal owner to its own
  # tombstone, but before it unlinked the mutex, runs the EXIT path, which
  # re-acquires the same dead-owner lock. Its own tombstone must not wedge it.
  local dir state lockdir rc
  dir=$(make_case lock-own-steal-tomb)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  printf '%s\n' "$(dead_pid)" > "$lockdir/pid"
  leave_dead_link_locks "$state" "$lockdir.steal"

  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_current_pid me || exit 6
    owner=$(fm_lock_link_owner "$2.steal") || exit 6
    mv -- "$owner" "$owner.reaped.$me" || exit 7
    fm_lock_try_acquire "$2" || exit 8
    [ "$(cat "$2/pid" 2>/dev/null)" = "$me" ] || exit 9
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -eq 0 ] || fail "own interrupted steal reap blocked reclaiming a dead-owner lock (rc=$rc)"
  [ ! -e "$lockdir.steal" ] && [ ! -L "$lockdir.steal" ] \
    || fail "own interrupted steal reap left the steal mutex linked"
  pass "a steal reap interrupted in this process is resumed from its own tombstone"
}

test_lock_steal_reap_cannot_remove_successor() {
  # Two reapers verify the same dead steal owner. The competitor runs to
  # completion exactly when the first one is about to remove the link; at most
  # one of them may end up believing it holds the mutex.
  local dir state steal fakebin out rc
  dir=$(make_case lock-steal-reap-race)
  state="$dir/state"
  steal="$state/.contend.lock.steal"
  fakebin="$dir/fakebin"
  out="$dir/competitor"
  leave_dead_link_locks "$state" "$steal"
  # The killed fixture owner may have its PID reused during a loaded serial
  # shard. Pin a verified-dead PID so the race exercises reaping, not liveness.
  printf '%s\n' "$(dead_pid)" > "$steal/pid"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
last=
for arg do last=$arg; done
if [ "$last" = "$FM_TEST_RACE_PATH" ] && mkdir "$FM_TEST_RACE_ONCE" 2>/dev/null; then
  bash -c '
    . "$1"
    if fm_lock_try_acquire_steal_mutex "$2"; then
      printf "won %s\n" "${BASHPID:-$$}" > "$3"
      exec sleep 30
    fi
    printf "lost\n" > "$3"
  ' _ "$FM_TEST_LIB" "$last" "$FM_TEST_RACE_OUT" >/dev/null 2>&1 &
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$FM_TEST_RACE_OUT" ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"

  rc=0
  PATH="$fakebin:$PATH" FM_TEST_LIB="$LIB" FM_TEST_RACE_PATH="$steal" \
    FM_TEST_RACE_ONCE="$dir/race-once" FM_TEST_RACE_OUT="$out" \
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      fm_lock_try_acquire_steal_mutex "$2" || exit 1
      [ "$(cat "$2/pid" 2>/dev/null)" = "${BASHPID:-$$}" ] || exit 2
    ' _ "$LIB" "$steal" || rc=$?
  [ -d "$dir/race-once" ] || fail "reap race hook never fired"
  case "$(cat "$out" 2>/dev/null || true)" in
    won\ *)
      kill -KILL "$(sed 's/^won //' "$out")" 2>/dev/null || true
      [ "$rc" -ne 0 ] || fail "competing reapers both hold the steal mutex"
      ;;
    lost)
      [ "$rc" -eq 0 ] || fail "no reaper acquired the dead steal mutex (rc=$rc)"
      ;;
    *) fail "competing reaper did not report an outcome" ;;
  esac
  pass "a competing reaper cannot remove the successor's steal mutex"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker gate hold i pids pid waiter winner wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  gate="$dir/first-winner"
  hold="$dir/winner-release"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  mkfifo "$gate" "$hold"
  # try_acquire is nonblocking: all one-shot candidates may lose to a transient
  # steal mutex. A waiting contender guarantees eventual acquisition, and the
  # FIFO keeps the winner alive until every other contender has finished.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    printf "%s\n" "${BASHPID:-$$}" >> "$3"
    printf "%s\n" "${BASHPID:-$$}" > "$4"
    IFS= read -r _ < "$5"
  ' _ "$LIB" "$lockdir" "$marker" "$gate" "$hold" &
  waiter=$!
  pids=
  i=1
  while [ "$i" -le 39 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        printf "%s\n" "${BASHPID:-$$}" > "$4"
        IFS= read -r _ < "$5"
      fi
    ' _ "$LIB" "$lockdir" "$marker" "$gate" "$hold" &
    pids="$pids $!"
    i=$((i + 1))
  done
  IFS= read -r winner < "$gate"
  [ "$winner" = "$waiter" ] || { kill "$waiter" 2>/dev/null || true; wait "$waiter" 2>/dev/null || true; }
  for pid in $pids; do
    [ "$pid" = "$winner" ] || wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  printf 'release\n' > "$hold"
  wait "$winner" 2>/dev/null || true
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

# The oracle is the public lock contract, not the representation: one live
# owner, same-owner recovery, dead-owner recovery and complete release must
# produce identical results with real links and with MSYS-style copied links.
lock_portability_scenario() {
  local state=$1 expected=$2
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$STATE/.portable.lock"
    fm_lock_try_acquire "$lock" || exit 10
    if [ "$2" = directory ]; then
      [ -d "$lock" ] && [ ! -L "$lock" ] || exit 11
    else
      [ -L "$lock" ] || exit 12
    fi
    owner=$(fm_lock_link_owner "$lock") || exit 13
    fm_lock_points_to_owner "$lock" "$owner" || exit 14
    printf "acquired\n"
    fm_lock_try_acquire "$lock" || exit 15
    printf "reentered\n"
    ( fm_lock_try_acquire "$lock" && exit 16
      fm_lock_release "$lock"
      [ -d "$lock" ] || exit 17
    ) || exit $?
    printf "refused foreign owner\n"
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 18
    printf "released\n"
    # wait is the proof that both the primary and steal holders have exited.
    bash -c '\''. "$1"; fm_lock_try_create "$2" && fm_lock_try_create "$2.steal"'\'' _ "$1" "$lock" &
    dead=$!
    wait "$dead" || exit 19
    fm_lock_try_acquire "$lock" || exit 20
    printf "reclaimed dead owner and steal mutex\n"
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -e "$lock.steal" ] || exit 21
    [ -z "$(find "$STATE" -name "*.owner.*" -print)" ] || exit 22
    printf "released reclaimed lock\n"
    fm_current_pid caller || exit 23
    bash -c '\''. "$1"; _fm_lock_acquire_wait_handoff "$2" "$3"'\'' _ "$1" "$lock" "$caller" &
    helper=$!
    wait "$helper" || exit 24
    [ "$(cat "$lock/pid")" = "$caller" ] || exit 25
    fm_lock_release "$lock"
    [ ! -e "$lock" ] || exit 26
    [ -z "$(find "$STATE" -name "*.owner.*" -print)" ] || exit 27
    printf "handed off and released\n"
  ' _ "$LIB" "$expected"
}

# The safe implementation must leave raw directories to main's existing
# steal-serialized recovery, rather than rename a mutable path in the reaper.
# Preserve the failing FIFO interleaving if that raw reaper is reintroduced.
test_direct_directory_reaper_cannot_remove_live_successor() {
  local dir state lock dead reaper successor event rc preserved
  dir=$(make_case direct-directory-successor-race)
  state="$dir/state"
  lock="$state/.raw.lock"
  dead=$(dead_pid)
  mkdir "$lock"
  printf '%s\n' "$dead" > "$lock/pid"
  mkfifo "$dir/events" "$dir/a-resume" "$dir/b-ready" "$dir/b-resume"
  exec 6<> "$dir/events" 7<> "$dir/a-resume" 8<> "$dir/b-ready" 9<> "$dir/b-resume"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock=$2
    trap '\''printf "exited:%s\n" "$?" >&6'\'' EXIT
    mv() {
      if [ "$1" = -- ] && [ "$2" = "$lock" ]; then
        printf "moving\n" >&6
        IFS= read -r resume <&7
      fi
      command mv "$@"
    }
    fm_lock_reap_dead_link "$lock"
  ' _ "$LIB" "$lock" &
  reaper=$!
  IFS= read -r event <&6
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 20
    printf "ready\n" >&8
    IFS= read -r release <&9
    fm_lock_release "$2"
  ' _ "$LIB" "$lock" &
  successor=$!
  IFS= read -r rc <&8
  [ "$rc" = ready ] && [ "$(cat "$lock/pid")" = "$successor" ] \
    || fail "main recovery did not publish its successor identity"
  kill -0 "$successor" || fail "successor exited before reaper resumed"
  if [ "$event" = moving ]; then
    printf 'resume\n' >&7
    IFS= read -r rc <&6
  fi
  rc=0
  wait "$reaper" || rc=$?
  preserved=false
  if [ -e "$lock" ] && kill -0 "$successor" 2>/dev/null; then preserved=true; fi
  printf 'release\n' >&9
  wait "$successor" || fail "successor could not release its own lock"
  exec 6>&- 7>&- 8>&- 9>&-
  [ "$event" = exited:1 ] && [ "$rc" -eq 1 ] && [ "$preserved" = true ] \
    || fail "direct-directory reaper reached rename or removed a live successor"
  pass "raw-directory reaper leaves main recovery and its live successor untouched"
}

test_direct_directory_lock_release_and_reap() {
  local dir state lock dead
  dir=$(make_case direct-directory-lock)
  state="$dir/state"
  lock="$state/.direct.lock"
  dead=$(dead_pid)
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_current_pid me || exit 1
    mkdir "$2" || exit 2
    printf "%s\n" "$me" > "$2/pid" || exit 3
    fm_lock_release "$2"
    [ ! -e "$2" ] || exit 4
    mkdir "$2" || exit 5
    printf "%s\n" "$3" > "$2/pid" || exit 6
    fm_lock_try_acquire "$2" || exit 7
    [ -e "$2" ] || exit 8
    fm_lock_release "$2"
    [ ! -e "$2" ] || exit 9
  ' _ "$LIB" "$lock" "$dead" || fail "direct directory lock was not releasable and reclaimable"
  pass "direct directory locks release and recover through the shared paths"
}

# Link-mode on-disk layout after each lock transition, normalized only for the
# random owner nonce, the holder pids and their recorded start times.
link_mode_layout_transcript() {  # <state>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    lock="$STATE/.parity.lock"
    real=$(cd "$STATE" && pwd -P) || exit 1
    fm_current_pid self || exit 1
    snap() {
      local entry kind
      printf "%s:" "$1"
      ( cd "$STATE" && find . -mindepth 1 -print | LC_ALL=C sort ) | while IFS= read -r entry; do
        if [ -L "$STATE/$entry" ]; then
          kind="link->$(readlink "$STATE/$entry")"
        elif [ -d "$STATE/$entry" ]; then
          kind=dir
        else
          kind="file=$(cat "$STATE/$entry")"
        fi
        printf " %s[%s]" "$entry" "$kind"
      done | sed -e "s#$real#STATE#g" -e "s#\.owner\.[A-Za-z0-9]\{6\}#.owner.N#g" \
        -e "s#=$self\]#=self]#g" -e "s#=${2:-none}\]#=other]#g" \
        -e "s#pid-start\[file=[^]]*\]#pid-start[file=start]#g"
      printf "\n"
    }
    fm_lock_try_acquire "$lock" || exit 2
    snap acquired
    fm_lock_set_role "$lock" autoarm || exit 3
    snap role
    fm_lock_try_acquire "$lock" || exit 4
    snap reentered
    fm_lock_release "$lock"
    snap released
    bash -c '\''. "$1"; fm_lock_try_create "$2"'\'' _ "$1" "$lock" &
    dead=$!
    wait "$dead" || exit 5
    snap dead-held "$dead"
    fm_lock_try_acquire "$lock" || exit 6
    [ "$FM_LOCK_RECOVERED_PID" = "$dead" ] || exit 7
    snap recovered
    fm_lock_release "$lock"
    snap released-recovered
    bash -c '\''. "$1"; _fm_lock_acquire_wait_handoff "$2" "$3"'\'' _ "$1" "$lock" "$self" &
    wait "$!" || exit 8
    snap handed-off
    fm_lock_release "$lock"
    snap released-handoff
  ' _ "$LIB"
}

# Real symlinks keep the link record exactly: a symlink to one sibling owner
# directory holding the known files, removed completely on release.
test_link_mode_layout_is_unchanged() {
  local dir out expected link owner
  dir=$(make_case link-mode-layout)
  out=$(link_mode_layout_transcript "$dir/state") || fail "link-mode layout scenario failed: $out"
  link='./.parity.lock[link->STATE/.parity.lock.owner.N] ./.parity.lock.owner.N[dir]'
  owner='./.parity.lock.owner.N/pid'
  self="${owner}[file=self] ${owner}-start[file=start]"
  expected="acquired: $link $self
role: $link $self ./.parity.lock.owner.N/role[file=autoarm]
reentered: $link $self
released:
dead-held: $link ${owner}[file=other] ${owner}-start[file=start]
recovered: $link $self
released-recovered:
handed-off: $link $self
released-handoff:"
  [ "$out" = "$expected" ] || fail "link-mode lock layout changed:
$out"
  pass "real-symlink locks keep the link layout through acquire, role, re-entry, recovery, handoff and release"
}

# Real symlinks keep main's removal semantics: removing a link discards only
# the owner's known files, so an unknown entry keeps the owner directory, and a
# stale-lock clear removes a link whose owner directory is already gone.
test_link_mode_removal_is_unchanged() {
  local dir state out
  dir=$(make_case link-mode-removal)
  state="$dir/state"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$STATE/.removal.lock"
    bash -c '\''. "$1"; fm_lock_try_create "$2"'\'' _ "$1" "$lock" || exit 1
    owner=$(readlink "$lock") || exit 2
    printf "x\n" > "$owner/unknown"
    fm_lock_remove_path "$lock" || exit 3
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 4
    [ -f "$owner/unknown" ] && [ ! -e "$owner/pid" ] || exit 5
    printf "removed link, kept owner with unknown entry\n"
    rm -rf "$owner"
    bash -c '\''. "$1"; fm_lock_try_create "$2"'\'' _ "$1" "$lock" || exit 6
    rm -rf "$(readlink "$lock")"
    fm_recovery_transition "$STATE/.watcher-down" clear-stale-lock "$lock" downtime || exit 7
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 8
    printf "cleared dangling link\n"
  ' _ "$LIB") || fail "link-mode removal changed (exit $?): $out"
  pass "real-symlink locks keep main's owner discard and dangling stale-lock clear"
}

test_lock_without_real_symlinks() {
  local native copied native_out copied_out real_ln
  native=$(make_case lock-native-parity)
  copied=$(make_case lock-copy-parity)
  real_ln=$(command -v ln)
  cat > "$copied/fakebin/ln" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -s ]; then
  exec cp -R "$2" "$3"
fi
exec "$FM_TEST_REAL_LN" "$@"
SH
  chmod +x "$copied/fakebin/ln"
  native_out=$(lock_portability_scenario "$native/state" symlink) \
    || fail "native symlink lock contract failed"
  copied_out=$(PATH="$copied/fakebin:$PATH" FM_TEST_REAL_LN="$real_ln" \
    lock_portability_scenario "$copied/state" directory) \
    || fail "MSYS copied-link lock contract failed"
  [ "$native_out" = "$copied_out" ] \
    || fail "directory fallback changed the native lock contract: $copied_out"
  pass "copied-link fallback matches native acquire, re-entry, refusal, dead-owner recovery and release"
}

test_directory_lock_single_winner_under_load() {
  local dir state round i pids pid winners result
  dir=$(make_case directory-lock-contention)
  state="$dir/state"
  cat > "$dir/fakebin/ln" <<'SH'
#!/usr/bin/env bash
exec cp -R "$2" "$3"
SH
  chmod +x "$dir/fakebin/ln"
  mkfifo "$dir/ready" "$dir/start" "$dir/result" "$dir/release"
  exec 6<> "$dir/ready" 7<> "$dir/start" 8<> "$dir/result" 9<> "$dir/release"
  for round in {1..10}; do
    pids=''
    winners=0
    for i in {1..8}; do
      PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" bash -c '
        . "$1"
        printf "ready\n" >&6
        IFS= read -r go <&7
        if fm_lock_try_acquire "$2"; then
          [ -d "$2" ] && [ ! -L "$2" ] || exit 10
          printf "won\n" >&8
          IFS= read -r release <&9
          fm_lock_release "$2"
        else
          printf "lost\n" >&8
        fi
      ' _ "$LIB" "$state/.contend.lock" &
      pids="$pids $!"
    done
    for i in {1..8}; do IFS= read -r result <&6; done
    for i in {1..8}; do printf 'go\n' >&7; done
    for i in {1..8}; do
      IFS= read -r result <&8
      [ "$result" != won ] || winners=$((winners + 1))
    done
    [ "$winners" -eq 1 ] || fail "directory contention round $round had $winners winners"
    printf 'release\n' >&9
    for pid in $pids; do wait "$pid" || fail "directory contender failed in round $round"; done
    [ ! -e "$state/.contend.lock" ] || fail "directory winner did not release in round $round"
    [ -z "$(find "$state" -name '*.owner.*' -print)" ] \
      || fail "directory contention round $round left owner entries: $(find "$state" -name '*.owner.*' -print)"
  done
  exec 6>&- 7>&- 8>&- 9>&-
  pass "directory lock has exactly one winner in 10 event-synchronized rounds of 8 contenders"
}

# --- copied-link directory-record protocol -----------------------------------
# These cases force directory mode with a copying ln and pause or kill the
# protocol's external children through barrier shims. A subject sets
# FM_TEST_BARRIERS to space-separated role:stage:action:lock specs; each spec
# fires once per subject. A firing shim appends
# "<subject> <role>:<stage>:<lock> pid=<shim> caller=<frame>" to FM_TEST_EVENTS,
# then acts: wait (block on FM_TEST_RESUME), kill (SIGKILL the calling frame),
# fail (skip the operation, exit 1) or none. A pre-stage shim reports
# "<subject> done rc=<rc>" after the real operation, so an orphaned child's
# outcome is observable after its frame died.
# Roles: publish = perl rename onto <lock>; retire = perl rename of <lock>/pid;
# discard = rm -rf <lock>/.owner.* (stage partial deletes pid.retired only);
# husk = rmdir <lock>. Stage skip-role drops <lock>/role from a retire rename.
dirlock_case() {  # <name>
  local dir tool
  dir=$(make_case "$1")
  # shellcheck disable=SC2016 # The shim expands its own arguments.
  printf '#!/usr/bin/env bash\nif [ "$1" = -s ]; then exec cp -R "$2" "$3"; fi\nexec %q "$@"\n' \
    "$(command -v ln)" > "$dir/fakebin/ln"
  chmod +x "$dir/fakebin/ln"
  for tool in perl rm rmdir; do
    { printf '#!/usr/bin/env bash\nFM_TEST_TOOL=%s\nFM_TEST_REAL=%q\n' "$tool" "$(command -v "$tool")"
      cat <<'SH'
set -u
[ -n "${FM_TEST_BARRIERS:-}" ] || exec "$FM_TEST_REAL" "$@"
barrier_match() {
  local spec i=0 r s a l
  for spec in $FM_TEST_BARRIERS; do
    i=$((i + 1))
    IFS=: read -r r s a l <<< "$spec"
    case "$FM_TEST_TOOL:$r" in
      perl:publish) [ "${!#}" = "$l" ] || continue ;;
      perl:retire) case " $* " in *" $l/pid "*) ;; *) continue ;; esac ;;
      rm:discard) [ "$#" -eq 2 ] && [ "$1" = -rf ] || continue
        case "$2" in "$l"/.owner.*) ;; *) continue ;; esac ;;
      rm:cleanup) [ "${2:-}" = "$l/pid" ] || continue ;;
      rmdir:husk|rmdir:cleanup) [ "$#" -eq 1 ] && [ "$1" = "$l" ] || continue ;;
      *) continue ;;
    esac
    mkdir "$FM_TEST_BARRIER_DIR/fired.$i" 2>/dev/null || continue
    role=$r stage=$s action=$a lock=$l
    return 0
  done
  return 1
}
barrier() {
  printf '%s %s:%s:%s pid=%s caller=%s\n' "$FM_TEST_SUBJECT" "$role" "$stage" "$lock" "$$" "$PPID" >> "$FM_TEST_EVENTS"
  case "$action" in
    wait) IFS= read -r _ < "$FM_TEST_RESUME" ;;
    kill) kill -KILL "$PPID"; exit 1 ;;
    fail) exit 1 ;;
  esac
}
barrier_match "$@" || exec "$FM_TEST_REAL" "$@"
case "$stage" in
  pre)
    barrier
    rc=0; "$FM_TEST_REAL" "$@" || rc=$?
    printf '%s done rc=%s\n' "$FM_TEST_SUBJECT" "$rc" >> "$FM_TEST_EVENTS"
    exit "$rc" ;;
  post) rc=0; "$FM_TEST_REAL" "$@" || rc=$?; barrier; exit "$rc" ;;
  partial) "$FM_TEST_REAL" -f "$2/pid.retired"; barrier; exit 1 ;;
  skip-role)
    args=()
    for arg in "$@"; do [ "$arg" = "$lock/role" ] || args+=("$arg"); done
    barrier; exec "$FM_TEST_REAL" "${args[@]}" ;;
esac
SH
    } > "$dir/fakebin/$tool"
    chmod +x "$dir/fakebin/$tool"
  done
  mkfifo "$dir/events"
  printf '%s\n' "$dir"
}

# dirlock_spawn <dir> <subject> <barriers> <script> [args...] - run with `&`:
# it execs the subject so $! is the subject frame. The script sees the lock
# library loaded and its own arguments as "$@". Output goes to the case's
# <subject>.log so a subject left paused by a failed case holds no test pipe.
dirlock_spawn() {
  local dir=$1 subject=$2 barriers=$3 script=$4
  shift 4
  mkdir -p "$dir/barrier.$subject"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_TEST_SUBJECT="$subject" \
    FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}" \
    FM_TEST_BARRIERS="$barriers" FM_TEST_BARRIER_DIR="$dir/barrier.$subject" \
    FM_TEST_EVENTS="$dir/events" FM_TEST_RESUME="$dir/resume.$subject" \
    exec "${DIRLOCK_BASH:-bash}" -c ". \"\$0\"; $script" "$LIB" "$@" >> "$dir/$subject.log" 2>&1
}

# Open the shared event stream on fd 6 and one resume FIFO per named subject
# on fds 7, 8, 9 in order.
dirlock_open() {  # <dir> <subject>...
  local dir=$1 fd=7 subject
  shift
  exec 6<> "$dir/events"
  for subject in "$@"; do
    mkfifo "$dir/resume.$subject"
    eval "exec $fd<> \"\$dir/resume.\$subject\""
    fd=$((fd + 1))
  done
}

dirlock_close() {
  exec 6>&- 7>&- 8>&- 9>&-
}

# Read the next event and require its prefix; leaves the line in DIRLOCK_EVENT.
dirlock_expect() {  # <prefix> <failure>
  DIRLOCK_EVENT=
  IFS= read -r -t 30 DIRLOCK_EVENT <&6 || fail "$2 (no event, expected '$1')"
  case "$DIRLOCK_EVENT" in
    "$1"*) ;;
    *) fail "$2 (event '$DIRLOCK_EVENT', expected '$1')" ;;
  esac
}

dirlock_event_field() {  # <field>
  local value=${DIRLOCK_EVENT##* "$1"=}
  printf '%s\n' "${value%% *}"
}

# The lock's generation directory path (the glob itself when there is none).
dirlock_generation() {  # <lock>
  local generation
  for generation in "$1"/.owner.*; do :; done
  printf '%s\n' "$generation"
}

# Everything under the state directory.
dirlock_tree() {  # <dir>
  (cd "$1/state" && find . -mindepth 1 -print | LC_ALL=C sort)
}

dirlock_assert_clean() {  # <dir> <failure>
  local left
  left=$(dirlock_tree "$1")
  [ -z "$left" ] || fail "$2: left $left"
}

# A holder script: acquire, publish identity and pid, wait for resume, release.
# shellcheck disable=SC2016 # Expanded by the subject shell.
DIRLOCK_HOLD='sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 9
fm_lock_try_acquire "$1" || exit 10
printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
IFS= read -r _ < "$FM_TEST_RESUME"
fm_lock_release "$1"'

test_dirlock_d1_unpublished_staging_is_private() {
  local dir lock publisher contender staging rc
  dir=$(dirlock_case "dirlock-d1${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a b
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "publish:pre:wait:$lock" '
    fm_lock_try_acquire "$1"; printf "%s\n" "$?" > "$2"' "$lock" "$dir/a.rc" &
  publisher=$!
  dirlock_expect "a publish:pre:$lock" "D1: publisher did not reach its publication rename"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "D1: L absent at barrier"
  for staging in "$lock".owner.*; do :; done
  [ -f "$staging/pid" ] && [ -d "$staging/.owner.${staging##*.owner.}" ] \
    || fail "D1: staged record is incomplete before publication: $(dirlock_tree "$dir")"
  dirlock_spawn "$dir" b "" "$DIRLOCK_HOLD" "$lock" "$dir/b.id" &
  contender=$!
  dirlock_expect "b held pid=$contender" "D1: contender did not acquire while the publisher was staged"
  printf 'go\n' >&7
  dirlock_expect "a done rc=1" "D1: publication rename did not fail onto the held lock"
  wait "$publisher" || fail "D1: publisher subject failed"
  rc=$(cat "$dir/a.rc")
  [ "$rc" = 1 ] || fail "D1: publisher acquired a held lock (rc=$rc)"
  [ ! -e "$staging" ] || fail "D1: publisher left its staging directory after a refused publication"
  [ "$(cat "$lock/pid")" = "$contender" ] || fail "D1: contender record changed"
  printf 'go\n' >&8
  wait "$contender" || fail "D1: contender could not release"
  dirlock_close
  dirlock_assert_clean "$dir" "D1: lock residue"
  pass "D1${DIRLOCK_TAG:-}: a staged directory record stays private and its creator discards it on refusal"
}

test_dirlock_d2_published_record_is_complete() {
  local dir lock publisher out generations
  dir=$(dirlock_case "dirlock-d2${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "publish:post:wait:$lock" '
    sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 9
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"' "$lock" "$dir/a.id" &
  publisher=$!
  dirlock_expect "a publish:post:$lock" "D2: publisher did not reach the end of its publication rename"
  [ "$(cat "$dir/a.id")" = "$publisher" ] || fail "D2: publisher identity is not its frame pid"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" "${DIRLOCK_BASH:-bash}" -c '
    . "$0"
    if fm_lock_try_acquire "$1"; then echo stolen; else echo "held=$FM_LOCK_HELD_PID"; fi' "$LIB" "$lock")
  [ "$out" = "held=$publisher" ] || fail "D2: contender did not see the publisher hold a complete record: $out"
  [ "$(cat "$lock/pid")" = "$publisher" ] || fail "D2: L/pid is not the publisher"
  generations=$(cd "$lock" && find . -mindepth 1 -maxdepth 1 -name '.owner.*' -type d | wc -l | tr -d ' ')
  [ "$generations" = 1 ] || fail "D2: published record has $generations generation directories"
  printf 'go\n' >&7
  wait "$publisher" || fail "D2: publisher could not claim and release"
  dirlock_close
  dirlock_assert_clean "$dir" "D2: release residue"
  [ -z "$(find "$dir/state" -name '*.owner.*' -print)" ] || fail "D2: owner residue"
  pass "D2${DIRLOCK_TAG:-}: a just-published directory record is complete and owned by its live publisher"
}

test_dirlock_d3_dead_holder_recovers_without_age() {
  local dir lock holder stale out
  for stale in 0 3600; do
    dir=$(dirlock_case "dirlock-d3-$stale${DIRLOCK_TAG:-}")
    lock="$dir/state/.d.lock"
    dirlock_open "$dir" a
    dirlock_spawn "$dir" a "" "$DIRLOCK_HOLD" "$lock" "$dir/a.id" &
    holder=$!
    dirlock_expect "a held pid=$holder" "D3: holder did not acquire"
    [ "$(cat "$dir/a.id")" = "$holder" ] || fail "D3: holder identity is not its frame pid"
    kill -KILL "$holder"
    wait "$holder" 2>/dev/null
    ! kill -0 "$holder" 2>/dev/null || fail "D3: holder survived SIGKILL"
    # shellcheck disable=SC2016
    out=$(PATH="$dir/fakebin:$PATH" FM_LOCK_STALE_AFTER=$stale FM_STATE_OVERRIDE="$dir/state" \
      "${DIRLOCK_BASH:-bash}" -c '
      . "$0"
      fm_lock_try_acquire "$1" || { echo "refused held=$FM_LOCK_HELD_PID"; exit 0; }
      echo "recovered=$FM_LOCK_RECOVERED_PID"
      fm_lock_release "$1"' "$LIB" "$lock")
    [ "$out" = "recovered=$holder" ] || fail "D3: dead holder not recovered with stale-after=$stale: $out"
    dirlock_close
    dirlock_assert_clean "$dir" "D3: recovery residue"
  done
  pass "D3${DIRLOCK_TAG:-}: a dead directory holder is recovered at once regardless of age"
}

test_dirlock_d4_crashed_release_is_finished() {
  local dir lock holder spec out generation
  for spec in retire:post discard:partial husk:pre; do
    dir=$(dirlock_case "dirlock-d4-${spec%%:*}")
    lock="$dir/state/.d.lock"
    dirlock_open "$dir" a
    # shellcheck disable=SC2016
    dirlock_spawn "$dir" a "$spec:kill:$lock" '
      fm_lock_try_acquire "$1" || exit 10
      fm_lock_release "$1"
      exit 11' "$lock" &
    holder=$!
    dirlock_expect "a $spec:$lock" "D4: releaser did not reach $spec"
    wait "$holder" 2>/dev/null
    ! kill -0 "$holder" 2>/dev/null || fail "D4: releaser survived its $spec kill"
    generation=$(dirlock_generation "$lock")
    case "$spec" in
      retire:post)
        [ ! -e "$lock/pid" ] && [ -f "$generation/pid.retired" ] \
          || fail "D4: retire post is not a committed retirement: $(dirlock_tree "$dir")" ;;
      discard:partial)
        [ ! -e "$lock/pid" ] && [ -f "$generation/pid" ] && [ ! -e "$generation/pid.retired" ] \
          || fail "D4: discard partial is not a partly deleted generation: $(dirlock_tree "$dir")" ;;
      husk:pre)
        [ -d "$lock" ] && [ "$(dirlock_tree "$dir")" = ./.d.lock ] \
          || fail "D4: husk pre is not an empty lock directory: $(dirlock_tree "$dir")" ;;
    esac
    # shellcheck disable=SC2016
    out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$0"
      fm_lock_try_acquire "$1" || { echo refused; exit 0; }
      echo "recovered=$FM_LOCK_RECOVERED_PID"
      fm_lock_release "$1"' "$LIB" "$lock")
    if [ "$spec" = husk:pre ]; then
      [ "$out" = refused ] || fail "D4: an empty lock directory was taken inside its grace: $out"
      touch -t 200001010000 "$lock"
      # shellcheck disable=SC2016
      out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
        . "$0"
        fm_lock_try_acquire "$1" || { echo refused; exit 0; }
        echo acquired
        fm_lock_release "$1"' "$LIB" "$lock")
      [ "$out" = acquired ] || fail "D4: an aged empty lock directory was not recovered: $out"
    else
      [ "$out" = "recovered=$holder" ] || fail "D4: crashed release at $spec was not finished: $out"
    fi
    dirlock_close
    dirlock_assert_clean "$dir" "D4: $spec residue"
  done
  pass "D4: a release killed after commit, mid-delete or before the final rmdir is finished by the next acquirer"
}

test_dirlock_d4c_orphan_husk_cleanup_preserves_successor() {
  local mode dir lock holder acquirer successor orphan generation before after pid private_pid rc
  for mode in acquire reap acquire-boundary reap-boundary; do
    dir=$(dirlock_case "dirlock-d4c-$mode")
    lock="$dir/state/.d.lock"
    case "$mode" in reap*) lock="$lock.steal" ;; esac
    dirlock_open "$dir" a b c
    # shellcheck disable=SC2016 # The script body is expanded by the subject shell.
    dirlock_spawn "$dir" a "husk:pre:kill:$lock" '
      fm_lock_try_acquire "$1" || exit 10
      fm_lock_release "$1"' "$lock" &
    holder=$!
    dirlock_expect "a husk:pre:$lock" "D4c: releaser did not leave a husk"
    wait "$holder" 2>/dev/null
    [ -d "$lock" ] && [ "$(dirlock_tree "$dir")" = "./${lock##*/}" ] \
      || fail "D4c: crashed releaser did not leave an empty husk"
    touch -t 200001010000 "$lock"
    # shellcheck disable=SC2016 # The script body is expanded by the subject shell.
    dirlock_spawn "$dir" b "cleanup:pre:wait:$lock" '
      case "$2" in *-boundary)
        target=$1
        original=$(declare -f _fm_lock_dir_remove_path)
        eval "${original/_fm_lock_dir_remove_path/_fm_original_remove_path}"
        _fm_lock_dir_remove_path() {
          if [ "$1" != "$target" ]; then
            _fm_original_remove_path "$@"
            return
          fi
          local rc=0
          FM_TEST_BARRIERS= bash -c '\''
            . "$0"
            printf "%s cleanup:pre:%s pid=%s caller=%s\n" "$FM_TEST_SUBJECT" "$1" "$$" "$PPID" >> "$FM_TEST_EVENTS"
            IFS= read -r _ < "$FM_TEST_RESUME"
            rc=0; _fm_lock_dir_remove_path "$@" || rc=$?
            printf "%s done rc=%s\n" "$FM_TEST_SUBJECT" "$rc" >> "$FM_TEST_EVENTS"
            exit "$rc"
          '\'' "$0" "$@" || rc=$?
          return "$rc"
        }
      esac
      case "$2" in
        acquire*) fm_lock_try_acquire "$1" ;;
        reap*) fm_lock_reap_dead_link "$1" ;;
      esac' "$lock" "$mode" &
    acquirer=$!
    dirlock_expect "b cleanup:pre:$lock" "D4c: $mode did not reach husk cleanup"
    orphan=$(dirlock_event_field pid)
    [ "$(dirlock_event_field caller)" = "$acquirer" ] \
      || fail "D4c: cleanup child does not belong to the acquirer"
    kill -KILL "$acquirer"
    wait "$acquirer" 2>/dev/null
    kill -0 "$orphan" 2>/dev/null || fail "D4c: cleanup child did not survive its parent"
    dirlock_spawn "$dir" c "" "$DIRLOCK_HOLD" "$lock" "$dir/c.id" &
    successor=$!
    dirlock_expect "c held pid=$successor" "D4c: successor did not recover the abandoned husk"
    generation=$(dirlock_generation "$lock")
    before=$(dirlock_tree "$dir")
    printf 'go\n' >&8
    dirlock_expect "b done rc=" "D4c: orphan cleanup did not resume"
    rc=${DIRLOCK_EVENT##*=}
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    private_pid=$(cat "$generation/pid" 2>/dev/null || true)
    after=$(dirlock_tree "$dir")
    printf 'go\n' >&9
    wait "$successor" || fail "D4c: successor could not release"
    dirlock_close
    [ "$pid" = "$successor" ] && [ "$private_pid" = "$successor" ] && [ "$after" = "$before" ] \
      || fail "D4c: orphaned $mode cleanup changed the live successor's pid or generation"
    [ "$rc" = 1 ] || fail "D4c: orphan cleanup did not refuse the complete successor record"
    dirlock_assert_clean "$dir" "D4c: successor release residue"
  done
  pass "D4c: orphaned husk cleanup cannot unlink a live successor's pid or generation"
}

# D1b: a claim that fails after publication leaves its generation to
# retirement. Its first retirement commits and then fails to delete the
# generation; the claim's cleanup must not delete it outside retirement.
test_dirlock_d1b_failed_claim_leaves_generation_to_retirement() {
  local dir lock claimant
  dir=$(dirlock_case dirlock-d1b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  mkdir "$lock.steal"
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "discard:pre:fail:$lock" '
    if fm_lock_try_create "$1"; then out=acquired; else out=refused; fi
    printf "%s finished out=%s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"' "$lock" &
  claimant=$!
  dirlock_expect "a discard:pre:$lock" "D1b: the steal-blocked claim did not retire its generation"
  dirlock_expect "a finished out=refused" "D1b: a claim blocked by a steal mutex did not refuse"
  wait "$claimant" || fail "D1b: claimant subject failed"
  rmdir "$lock.steal"
  dirlock_close
  dirlock_assert_clean "$dir" "D1b: the generation was deleted outside retirement"
  pass "D1b: a claim that fails after publication leaves its generation to retirement"
}

# D4b: after a bounded handoff only L/pid names the caller, so a release by
# the caller killed after its commit is recovered as the caller, not as the
# helper whose pid the generation still records.
test_dirlock_d4b_handoff_release_recovers_caller() {
  local dir lock caller generation out
  dir=$(dirlock_case dirlock-d4b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" c
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" c "retire:post:kill:$lock" '
    printf "%s ready\n" "$FM_TEST_SUBJECT" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
    fm_lock_release "$1"
    exit 11' "$lock" &
  caller=$!
  dirlock_expect "c ready" "D4b: caller did not start"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; _fm_lock_acquire_wait_handoff "$1" "$2"' \
    "$LIB" "$lock" "$caller" || fail "D4b: helper could not hand the lock to the caller"
  generation=$(dirlock_generation "$lock")
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$caller" ] && [ -f "$generation/pid" ] \
    && [ "$(cat "$generation/pid")" != "$caller" ] \
    || fail "D4b: handoff did not change only L/pid: $(dirlock_tree "$dir")"
  printf 'go\n' >&7
  dirlock_expect "c retire:post:$lock" "D4b: caller release did not reach its committed retirement"
  wait "$caller" 2>/dev/null
  ! kill -0 "$caller" 2>/dev/null || fail "D4b: caller survived its retire kill"
  [ ! -e "$lock/pid" ] && [ "$(cat "$generation/pid.retired" 2>/dev/null)" = "$caller" ] \
    || fail "D4b: caller release is not a committed retirement: $(dirlock_tree "$dir")"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"
    fm_lock_try_acquire "$1" || { echo refused; exit 0; }
    echo "recovered=$FM_LOCK_RECOVERED_PID"
    fm_lock_release "$1"' "$LIB" "$lock")
  [ "$out" = "recovered=$caller" ] || fail "D4b: handed-off release was not recovered as the caller: $out"
  dirlock_close
  dirlock_assert_clean "$dir" "D4b: residue"
  pass "D4b: a handed-off release killed after commit is recovered as the caller"
}

test_dirlock_d5_orphan_retirement_cannot_touch_successor() {
  local dir lock holder orphan contender generation
  dir=$(dirlock_case dirlock-d5)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a b
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "retire:pre:wait:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"' "$lock" &
  holder=$!
  dirlock_expect "a retire:pre:$lock" "D5: holder did not reach its retirement rename"
  orphan=$(dirlock_event_field pid)
  [ "$(dirlock_event_field caller)" = "$holder" ] || fail "D5: barrier was not raised by the holder: $DIRLOCK_EVENT"
  kill -KILL "$holder"
  wait "$holder" 2>/dev/null
  ! kill -0 "$holder" 2>/dev/null || fail "D5: holder survived SIGKILL"
  kill -0 "$orphan" 2>/dev/null || fail "D5: retirement child died with its frame"
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" b "" "$DIRLOCK_HOLD" "$lock" "$dir/b.id" &
  contender=$!
  dirlock_expect "b held pid=$contender" "D5: contender did not recover the dead holder"
  generation=$(cd "$lock" && echo .owner.*)
  printf 'go\n' >&7
  dirlock_expect "a done rc=" "D5: orphaned retirement did not resume"
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$contender" ] || fail "D5: orphaned retirement took the successor's pid"
  [ "$(cd "$lock" && echo .owner.*)" = "$generation" ] && [ -f "$lock/$generation/pid" ] \
    || fail "D5: orphaned retirement changed the successor's generation: $(dirlock_tree "$dir")"
  printf 'go\n' >&8
  wait "$contender" || fail "D5: contender could not release cleanly"
  dirlock_close
  dirlock_assert_clean "$dir" "D5: residue"
  pass "D5: an orphaned retirement child resumed after recovery cannot touch the successor"
}

test_dirlock_d5b_stealer_retires_only_captured_generation() {
  local dir lock stealer sleeper live_stage out
  dir=$(dirlock_case dirlock-d5b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" s
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" bash -c '. "$0"; fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D5': could not leave a dead-held record"
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" s "retire:pre:wait:$lock" '
    if fm_lock_try_acquire "$1"; then echo acquired > "$2"; else echo "held=$FM_LOCK_HELD_PID" > "$2"; fi' \
    "$lock" "$dir/s.out" &
  stealer=$!
  dirlock_expect "s retire:pre:$lock" "D5': stealer did not reach its retirement rename"
  # The self-held reclaim's effect: the dead generation is retired and a live
  # one is published in its place while the stealer is paused.
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_remove_path "$1"' "$LIB" "$lock" \
    || fail "D5': could not retire the dead generation"
  [ ! -e "$lock" ] || fail "D5': dead generation retirement left the lock"
  sleep 300 &
  sleeper=$!
  live_stage="$dir/state/.d.lock.owner.live000"
  mkdir -p "$live_stage/.owner.live000"
  printf '%s\n' "$sleeper" > "$live_stage/pid"
  printf '%s\n' "$sleeper" > "$live_stage/.owner.live000/pid"
  mv "$live_stage" "$lock"
  printf 'go\n' >&7
  wait "$stealer" || fail "D5': stealer subject failed"
  out=$(cat "$dir/s.out")
  [ "$out" = "held=$sleeper" ] || fail "D5': stealer did not report the live successor: $out"
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$sleeper" ] && [ -f "$lock/.owner.live000/pid" ] \
    || fail "D5': stealer damaged the live record: $(dirlock_tree "$dir")"
  kill "$sleeper"
  wait "$sleeper" 2>/dev/null
  dirlock_close
  pass "D5': a paused stealer's retirement is addressed only to the generation it validated"
}

# A subject script that pauses its first directory-record removal of <lock>
# (the mutation after its stale recheck), runs <call> on <lock>, and reports
# "<subject> finished out=<result>" so a wrong outcome fails within the event
# deadline instead of blocking on the pause.
# shellcheck disable=SC2016 # Expanded by the subject shell.
DIRLOCK_PAUSE_REMOVE='target=$1 paused=
original=$(declare -f _fm_lock_dir_remove_path)
eval "${original/_fm_lock_dir_remove_path/_fm_original_remove_path}"
_fm_lock_dir_remove_path() {
  if [ -z "$paused" ] && [ "$1" = "$target" ]; then
    paused=1
    printf "%s remove:pre:%s\n" "$FM_TEST_SUBJECT" "$target" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
  fi
  _fm_original_remove_path "$@"
}'

# Replace the paused subject's dead record with a live successor held by this
# test shell, retiring the dead generation the way a competing reaper does.
dirlock_replace_with_live_successor() {  # <dir> <lock> <row>
  local dir=$1 lock=$2 row=$3 live_stage
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_remove_path "$1"' "$LIB" "$lock" \
    || fail "$row: could not retire the captured dead generation"
  [ ! -e "$lock" ] || fail "$row: dead generation retirement left the lock"
  live_stage="$lock.owner.live000"
  mkdir -p "$live_stage/.owner.live000"
  printf '%s\n' "$$" > "$live_stage/pid"
  printf '%s\n' "$$" > "$live_stage/.owner.live000/pid"
  mv "$live_stage" "$lock"
}

dirlock_assert_live_successor() {  # <dir> <lock> <row>
  [ "$(cat "$2/pid" 2>/dev/null)" = "$$" ] && [ -f "$2/.owner.live000/pid" ] \
    || fail "$3: successor record changed: $(dirlock_tree "$1")"
  rm -rf "$2"
}

test_dirlock_d5c_acquirer_retires_captured_generation() {
  local dir lock stealer
  dir=$(dirlock_case dirlock-d5c)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" s
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D5c: could not leave a dead-held record"
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" s "" "$DIRLOCK_PAUSE_REMOVE"'
    if fm_lock_try_acquire "$1"; then out=acquired; fm_lock_release "$1"; else out="held=$FM_LOCK_HELD_PID"; fi
    printf "%s finished out=%s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"' "$lock" &
  stealer=$!
  dirlock_expect "s remove:pre:$lock" "D5c: acquirer did not pause after its stale recheck"
  dirlock_replace_with_live_successor "$dir" "$lock" D5c
  printf 'go\n' >&7
  dirlock_expect "s finished out=" "D5c: acquirer did not finish"
  wait "$stealer" || fail "D5c: acquirer subject failed"
  [ "$(dirlock_event_field out)" = "held=$$" ] \
    || fail "D5c: acquirer damaged or took the successor: $DIRLOCK_EVENT"
  dirlock_assert_live_successor "$dir" "$lock" D5c
  dirlock_close
  dirlock_assert_clean "$dir" "D5c: residue"
  pass "D5c: stale acquisition retires only its captured generation"
}

# D8b: the direct reaper's mutation after its stale recheck is addressed to the
# generation it rechecked, not to whatever record the lock path holds by then.
test_dirlock_d8b_reaper_retires_captured_generation() {
  local dir lock reaper
  dir=$(dirlock_case dirlock-d8b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" r
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D8b: could not leave a dead-held record"
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" r "" "$DIRLOCK_PAUSE_REMOVE"'
    if fm_lock_reap_dead_link "$1"; then out=reaped; else out=refused; fi
    printf "%s finished out=%s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"' "$lock" &
  reaper=$!
  dirlock_expect "r remove:pre:$lock" "D8b: reaper did not pause after its stale recheck"
  dirlock_replace_with_live_successor "$dir" "$lock" D8b
  printf 'go\n' >&7
  dirlock_expect "r finished out=" "D8b: reaper did not finish"
  wait "$reaper" || fail "D8b: reaper subject failed"
  dirlock_assert_live_successor "$dir" "$lock" D8b
  dirlock_close
  dirlock_assert_clean "$dir" "D8b: residue"
  pass "D8b: a paused direct reaper retires only the generation it rechecked"
}

test_dirlock_d6_late_publication_is_ordinary_recovery() {
  local dir lock publisher orphan contender case_name out staging
  for case_name in held released; do
    dir=$(dirlock_case "dirlock-d6-$case_name")
    lock="$dir/state/.d.lock"
    dirlock_open "$dir" a b
    # shellcheck disable=SC2016
    dirlock_spawn "$dir" a "publish:pre:wait:$lock" 'fm_lock_try_acquire "$1"' "$lock" &
    publisher=$!
    dirlock_expect "a publish:pre:$lock" "D6: publisher did not reach its publication rename"
    orphan=$(dirlock_event_field pid)
    for staging in "$lock".owner.*; do :; done
    kill -KILL "$publisher"
    wait "$publisher" 2>/dev/null
    ! kill -0 "$publisher" 2>/dev/null || fail "D6: publisher survived SIGKILL"
    kill -0 "$orphan" 2>/dev/null || fail "D6: publication child died with its frame"
    dirlock_spawn "$dir" b "" "$DIRLOCK_HOLD" "$lock" "$dir/b.id" &
    contender=$!
    dirlock_expect "b held pid=$contender" "D6: contender did not acquire"
    if [ "$case_name" = held ]; then
      printf 'go\n' >&7
      dirlock_expect "a done rc=1" "D6: late publication did not fail onto the held lock"
      [ "$(cat "$lock/pid")" = "$contender" ] || fail "D6: late publication changed the holder"
      [ -d "$staging" ] || fail "D6: the dead publisher's staging directory vanished"
      printf 'go\n' >&8
      wait "$contender" || fail "D6: contender could not release"
      [ "$(dirlock_tree "$dir")" = "./${staging##*/}
./${staging##*/}/.owner.${staging##*.owner.}
./${staging##*/}/.owner.${staging##*.owner.}/pid
./${staging##*/}/pid
./${staging##*/}/pid-start" ] || fail "D6: unexpected leftovers besides the one inert staging directory: $(dirlock_tree "$dir")"
    else
      printf 'go\n' >&8
      wait "$contender" || fail "D6: contender could not release"
      printf 'go\n' >&7
      dirlock_expect "a done rc=0" "D6: late publication did not publish onto the absent lock"
      [ "$(cat "$lock/pid")" = "$publisher" ] || fail "D6: late publication is not held by its dead publisher"
      # shellcheck disable=SC2016
      out=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
        . "$0"
        fm_lock_try_acquire "$1" || { echo refused; exit 0; }
        echo "recovered=$FM_LOCK_RECOVERED_PID"
        fm_lock_release "$1"' "$LIB" "$lock")
      [ "$out" = "recovered=$publisher" ] || fail "D6: late dead-held publication was not recovered: $out"
      dirlock_assert_clean "$dir" "D6: residue after recovering a late publication"
    fi
    dirlock_close
  done
  pass "D6: a late publication by a dead publisher fails onto a holder or becomes an ordinary dead-held record"
}

test_dirlock_d7_handoff_transient_follows_generation_pid() {
  local dir lock sleeper out
  dir=$(dirlock_case "dirlock-d7${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  sleep 300 &
  sleeper=$!
  mkdir -p "$lock/.owner.handof"
  printf '%s\n' "$sleeper" > "$lock/.owner.handof/pid"
  : > "$lock/pid"
  touch -t 200001010000 "$lock" "$lock/pid"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" "${DIRLOCK_BASH:-bash}" -c '
    . "$0"
    if fm_lock_try_acquire "$1"; then echo stolen; else echo refused; fi' "$LIB" "$lock")
  [ "$out" = refused ] || fail "D7: an empty pid with a live generation pid was stolen: $out"
  [ -e "$lock/pid" ] && [ -f "$lock/.owner.handof/pid" ] || fail "D7: contender changed the handoff record"
  kill "$sleeper"
  wait "$sleeper" 2>/dev/null
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" "${DIRLOCK_BASH:-bash}" -c '
    . "$0"
    fm_lock_try_acquire "$1" || { echo refused; exit 0; }
    echo "recovered=$FM_LOCK_RECOVERED_PID"
    fm_lock_release "$1"' "$LIB" "$lock")
  [ "$out" = "recovered=$sleeper" ] || fail "D7: a dead handoff helper's record was not recovered: $out"
  dirlock_assert_clean "$dir" "D7: residue"
  pass "D7${DIRLOCK_TAG:-}: an empty handoff pid is held exactly while the generation's pid lives"
}

test_dirlock_d7b_bounded_helper_killed_by_deadline() {
  local dir lock holder caller out
  dir=$(dirlock_case dirlock-d7b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" h c
  dirlock_spawn "$dir" h "" "$DIRLOCK_HOLD" "$lock" "$dir/h.id" &
  holder=$!
  dirlock_expect "h held pid=$holder" "D7': holder did not acquire"
  # The caller announces its timed helper; the helper's own publication then
  # pauses until the deadline kills it before the handoff write.
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" c "publish:post:wait:$lock" '
    _fm_wake_require_timeout || exit 9
    eval "_dirlock_run_timed() $(declare -f fm_run_timed | tail -n +2)"
    fm_run_timed() { printf "c helper-start\n" >> "$FM_TEST_EVENTS"; _dirlock_run_timed "$@"; }
    sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 8
    rc=0; fm_lock_acquire_wait_bounded "$1" 2 || rc=$?
    printf "rc=%s pid=%s\n" "$rc" "$(cat "$1/pid" 2>/dev/null)" > "$3"
    [ "$rc" -ne 0 ] || fm_lock_release "$1"' "$lock" "$dir/c.id" "$dir/c.out" &
  caller=$!
  dirlock_expect "c helper-start" "D7': caller did not start its timed helper"
  printf 'go\n' >&7
  wait "$holder" || fail "D7': holder could not release"
  dirlock_expect "c publish:post:$lock" "D7': helper did not acquire after the holder released"
  wait "$caller" || fail "D7': caller subject failed"
  out=$(cat "$dir/c.out")
  [ "$out" = "rc=0 pid=$caller" ] || fail "D7': caller did not end holding after its helper was killed: $out"
  dirlock_close
  dirlock_assert_clean "$dir" "D7': residue"
  pass "D7': a bounded helper killed by its deadline after acquiring leaves the caller holding"
}

test_dirlock_d8_dead_steal_mutex_observers_compose() {
  local dir lock first second
  dir=$(dirlock_case dirlock-d8)
  lock="$dir/state/.d.lock"
  # shellcheck disable=SC2016
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" bash -c '
    . "$0"; fm_lock_try_create "$1" && fm_lock_try_create "$1.steal"' "$LIB" "$lock" \
    || fail "D8: could not leave dead primary and steal records"
  dirlock_open "$dir" a b
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" a "retire:pre:wait:$lock.steal publish:post:wait:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"' "$lock" &
  first=$!
  dirlock_expect "a retire:pre:$lock.steal" "D8: first observer did not reach the steal-mutex retirement"
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" b "retire:pre:wait:$lock.steal" '
    if fm_lock_try_acquire "$1"; then out=acquired; else out="held=$FM_LOCK_HELD_PID"; fi
    printf "%s result %s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
    fm_lock_try_acquire "$1" || exit 11
    fm_lock_release "$1"' "$lock" &
  second=$!
  dirlock_expect "b retire:pre:$lock.steal" "D8: second observer did not reach the steal-mutex retirement"
  printf 'go\n' >&7
  dirlock_expect "a done rc=" "D8: first observer's retirement did not finish"
  dirlock_expect "a publish:post:$lock" "D8: first observer did not publish the primary lock"
  [ "$(cat "$lock.steal/pid")" = "$first" ] && [ "$(cat "$lock/pid")" = "$first" ] \
    || fail "D8: first observer does not hold the steal mutex and the lock: $(dirlock_tree "$dir")"
  printf 'go\n' >&8
  dirlock_expect "b done rc=" "D8: second observer's late retirement did not run"
  dirlock_expect "b result held=$first" "D8: second observer did not report the first as holder"
  [ "$(cat "$lock.steal/pid")" = "$first" ] && [ "$(cat "$lock/pid")" = "$first" ] \
    || fail "D8: second observer's retirement touched the first's records: $(dirlock_tree "$dir")"
  printf 'go\n' >&7
  wait "$first" || fail "D8: first observer could not finish"
  printf 'go\n' >&8
  wait "$second" || fail "D8: second observer could not acquire after the first released"
  dirlock_close
  dirlock_assert_clean "$dir" "D8: residue"
  pass "D8: two observers of a dead directory steal mutex compose and cannot disturb the winner"
}

test_dirlock_d9_uncommitted_retirement_keeps_record() {
  local dir lock holder out
  dir=$(dirlock_case dirlock-d9)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "retire:pre:fail:$lock retire:pre:fail:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    rc=0; fm_lock_remove_path "$1" || rc=$?
    [ "$rc" -eq 1 ] || exit 11
    fm_lock_release "$1" || exit 12
    printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
    fm_lock_release "$1"' "$lock" &
  holder=$!
  dirlock_expect "a retire:pre:$lock" "D9: first retirement did not reach its rename"
  dirlock_expect "a retire:pre:$lock" "D9: release did not reach its rename"
  dirlock_expect "a held pid=$holder" "D9: failed retirement did not leave the holder's record"
  [ "$(cat "$(dirlock_generation "$lock")/pid")" = "$holder" ] \
    || fail "D9: failed retirement damaged the generation: $(dirlock_tree "$dir")"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"; if fm_lock_try_acquire "$1"; then echo stolen; else echo "held=$FM_LOCK_HELD_PID"; fi' "$LIB" "$lock")
  [ "$out" = "held=$holder" ] || fail "D9: contender took a record whose retirement failed: $out"
  printf 'go\n' >&7
  wait "$holder" || fail "D9: holder subject failed"
  dirlock_close
  dirlock_assert_clean "$dir" "D9: residue after the fault cleared"
  pass "D9: an uncommitted retirement leaves the complete held record and deletes nothing"
}

test_dirlock_d10_committed_retirement_is_finished() {
  local dir lock holder out expected
  dir=$(dirlock_case dirlock-d10)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "retire:skip-role:none:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_set_role "$1" autoarm || exit 11
    rc=0; fm_lock_remove_path "$1" || rc=$?
    [ "$rc" -eq 1 ] || exit 12' "$lock" &
  holder=$!
  dirlock_expect "a retire:skip-role:$lock" "D10: retirement did not reach its rename"
  wait "$holder" || fail "D10: remove_path did not report the unfinished retirement"
  expected=$(cd "$lock" && printf './%s\n' role .owner.* .owner.*/pid .owner.*/pid-start.retired .owner.*/pid.retired | LC_ALL=C sort)
  [ "$(cd "$lock" && find . -mindepth 1 -print | LC_ALL=C sort)" = "$expected" ] \
    || fail "D10: committed retirement left an unexpected record: $(dirlock_tree "$dir")"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"
    fm_lock_try_acquire "$1" || { echo refused; exit 0; }
    echo acquired
    fm_lock_release "$1"' "$LIB" "$lock")
  [ "$out" = acquired ] || fail "D10: contender did not finish a committed retirement: $out"
  dirlock_close
  dirlock_assert_clean "$dir" "D10: residue"
  pass "D10: a committed retirement blocked by a remaining known file is finished by the next acquirer"
}

test_dirlock_d11_ambiguous_generation_is_refused() {
  local dir lock holder before
  dir=$(dirlock_case dirlock-d11)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "" '
    fm_current_pid me || exit 9
    mkdir -p "$1/.owner.first1" "$1/.owner.secnd2" || exit 10
    printf "%s\n" "$me" > "$1/pid"
    printf "%s\n" "$me" > "$1/.owner.first1/pid"
    printf "%s\n" "$me" > "$1/.owner.secnd2/pid"
    ! fm_lock_link_owner "$1" >/dev/null || exit 11
    fm_lock_release "$1" || exit 12
    printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"' "$lock" &
  holder=$!
  dirlock_expect "a held pid=$holder" "D11: ambiguous record was not refused by its own holder"
  before=$(dirlock_tree "$dir")
  [ "$(printf '%s\n' "$before" | grep -c '/pid$')" = 3 ] || fail "D11: release touched the ambiguous record: $before"
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; ! fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D11: contender acquired an ambiguous live record"
  [ "$(dirlock_tree "$dir")" = "$before" ] || fail "D11: contender changed the ambiguous record"
  printf 'go\n' >&7
  wait "$holder" || fail "D11: holder subject failed"
  dirlock_close
  pass "D11: a record with more than one generation is invalid and never released or taken"
}

# D11c runs D11b on the watcher lock, whose stale recovery first publishes
# downtime evidence: an invalid record must be refused before that too.
test_dirlock_d11b_dead_ambiguous_generation_is_refused() {
  local dir lock dead before out row
  for row in D11b:.d.lock D11c:.watch.lock; do
    dir=$(dirlock_case "dirlock-${row%%:*}")
    lock="$dir/state/${row#*:}"
    row=${row%%:*}
    dirlock_open "$dir"
    dead=$(dead_pid)
    mkdir -p "$lock/.owner.first1" "$lock/.owner.secnd2"
    printf '%s\n' "$dead" > "$lock/pid"
    printf '%s\n' "$dead" > "$lock/.owner.first1/pid"
    printf '%s\n' "$dead" > "$lock/.owner.secnd2/pid"
    before=$(dirlock_tree "$dir")
    out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$0"
      if fm_lock_try_acquire "$1"; then echo acquired; else echo refused; fi' "$LIB" "$lock")
    [ "$out" = refused ] || fail "$row: contender acted on an invalid dead record: $out"
    [ "$(dirlock_tree "$dir")" = "$before" ] || fail "$row: invalid dead record or its state was changed: $(dirlock_tree "$dir")"
    dirlock_close
  done
  pass "D11b: an invalid dead record fails closed before destructive cleanup"
  pass "D11c: an invalid dead watcher record is refused before downtime evidence is published"
}

test_dirlock_d12_staging_litter_is_never_consulted() {
  local dir lock sleeper before
  dir=$(dirlock_case dirlock-d12)
  lock="$dir/state/.d.lock"
  sleep 300 &
  sleeper=$!
  mkdir -p "$lock.owner.livepb/.owner.livepb" "$lock.owner.deadpb/.owner.deadpb"
  printf '%s\n' "$sleeper" > "$lock.owner.livepb/pid"
  printf '%s\n' "$sleeper" > "$lock.owner.livepb/.owner.livepb/pid"
  printf '%s\n' "$(dead_pid)" > "$lock.owner.deadpb/pid"
  printf '%s\n' "$(dead_pid)" > "$lock.owner.deadpb/.owner.deadpb/pid"
  before=$(dirlock_tree "$dir")
  # shellcheck disable=SC2016
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"
    [ ! -e "$1" ] || exit 11
    fm_lock_try_acquire "$1" || exit 12
    fm_lock_release "$1"' "$LIB" "$lock" || fail "D12: staging litter interfered with acquire and release"
  [ "$(dirlock_tree "$dir")" = "$before" ] || fail "D12: lock operations changed staging litter: $(dirlock_tree "$dir")"
  kill "$sleeper"
  wait "$sleeper" 2>/dev/null
  pass "D12: staging directories beside a directory lock are never read or removed"
}

test_dirlock_d17_subshell_publisher_identity() {
  local dir lock holder recorded
  dir=$(dirlock_case "dirlock-d17${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "" '
    (
      sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 9
      fm_lock_try_acquire "$1" || exit 10
      printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
      IFS= read -r _ < "$FM_TEST_RESUME"
      fm_lock_release "$1"
    ) &
    wait "$!"' "$lock" "$dir/a.id" &
  holder=$!
  dirlock_expect "a held pid=" "D17: subshell publisher did not acquire"
  recorded=$(cat "$dir/a.id")
  [ "$(dirlock_event_field pid)" = "$recorded" ] && [ "$recorded" != "$holder" ] \
    && [ "$(cat "$(dirlock_generation "$lock")/pid")" = "$recorded" ] \
    || fail "D17: subshell publisher recorded $(dirlock_event_field pid), expected its own frame $recorded"
  printf 'go\n' >&7
  wait "$holder" || fail "D17: subshell publisher could not release"
  dirlock_close
  dirlock_assert_clean "$dir" "D17: residue"
  pass "D17${DIRLOCK_TAG:-}: a background-subshell publisher records its own frame identity"
}

# D17: the identity-sensitive cases also run under stock macOS Bash 3.2, whose
# fm_current_pid has no BASHPID. A shell whose version already ran is skipped:
# on Linux both names are the same Bash, and its rows would reuse the fixtures.
test_dirlock_identity_cases_per_shell() {
  local shell version seen=" "
  for shell in bash /bin/bash; do
    command -v "$shell" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016 # Expanded by the probed shell.
    version=$("$shell" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')
    case "$seen" in *" $version "*) continue ;; esac
    seen="$seen$version "
    DIRLOCK_BASH=$shell DIRLOCK_TAG="-bash-$version"
    export DIRLOCK_BASH
    test_dirlock_d1_unpublished_staging_is_private
    test_dirlock_d2_published_record_is_complete
    test_dirlock_d3_dead_holder_recovers_without_age
    test_dirlock_d7_handoff_transient_follows_generation_pid
    test_dirlock_d17_subshell_publisher_identity
  done
  unset DIRLOCK_BASH DIRLOCK_TAG
}

start_time_of() {  # <pid>
  FM_STATE_OVERRIDE="$TMP_ROOT" bash -c '. "$1"; fm_pid_start_time "$2"' _ "$LIB" "$1"
}

# The recorded holder died and the kernel handed its pid to an unrelated live
# process. Pid liveness alone reads that lock as held forever, so the record's
# holder start time must expose the reuse and let the next acquirer take it over.
test_lock_reclaims_reused_pid_lock() {
  local dir state lockdir owner unrelated out lockpid holder_start
  dir=$(make_case lock-reused-pid)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  owner="$lockdir.owner.fixture"
  # The original holder's start time: pid 1 started long before the process
  # that now occupies the recorded pid, so the two can never match.
  holder_start=$(start_time_of 1) || fail "could not read a start time for the fixture holder"
  sleep 300 &
  unrelated=$!
  mkdir "$owner"
  printf '%s\n' "$unrelated" > "$owner/pid"
  printf '%s\n' "$holder_start" > "$owner/pid-start"
  ln -s "$owner" "$lockdir"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s recovered=%s self=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" \
      "${FM_LOCK_RECOVERED_PID:-}" "${BASHPID:-$$}"
    [ "$rc" -ne 0 ] || fm_lock_release "$2"
  ' _ "$LIB" "$lockdir")
  is_live_non_zombie "$unrelated" || fail "reclaiming a reused-pid lock signalled the unrelated process"
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  case "$out" in
    *"rc=0"*) ;;
    *) fail "lock whose live pid no longer answers to its recorded holder was refused: $out" ;;
  esac
  case "$out" in
    *"recovered=$unrelated "*) ;;
    *) fail "reused-pid takeover did not report the pid it took over: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ -z "$lockpid" ] || fail "reused-pid takeover left a lock behind after release (pid '$lockpid')"
  pass "lock whose recorded holder pid was reused by a live process is reclaimed"
}

# A holder that took the lock through the library records its start time, and
# while it stays alive a contender still reads that record as held.
test_lock_respects_live_holder_matching_its_start_time() {
  local dir state lockdir holder i out recorded expected
  dir=$(make_case lock-live-identity)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" "$dir/holder.ready" "$dir/release-holder" &
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/holder.ready" ] \
    || { kill "$holder" 2>/dev/null || true; fail "identity fixture holder never acquired its lock"; }
  recorded=$(cat "$lockdir/pid-start" 2>/dev/null || true)
  expected=$(start_time_of "$holder" 2>/dev/null || true)
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; fm_lock_release "$2"; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  : > "$dir/release-holder"
  wait "$holder" || fail "identity fixture holder did not release cleanly"
  [ -n "$expected" ] && [ "$recorded" = "$expected" ] \
    || fail "lock record does not carry its live holder's start time (recorded '$recorded', expected '$expected')"
  case "$out" in
    *"rc=1 held=$holder"*) ;;
    *) fail "lock held by a live holder matching its recorded start time was not refused: $out" ;;
  esac
  pass "live holder matching its recorded start time keeps its lock"
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
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
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
  stop_seed_watcher "$wpid" "$out"
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
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
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
  stop_seed_watcher "$wpid" "$out"
  pass "attached arm signals record a classified lifecycle entry"
}

test_arm_term_during_steal_waits_for_watcher_cleanup_trap() {
  local dir state fakebin armout armpid i dead pidfile status
  dir=$(make_case arm-term-mid-steal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  pidfile="$dir/arm.pid"
  mkdir "$state/.watch.lock"
  dead=$(dead_pid)
  printf '%s\n' "$dead" > "$state/.watch.lock/pid"
  mkdir -p "$fakebin"
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
last=
for arg do last=$arg; done
case "$last" in
  *.watch.lock.steal)
    sleep 0.2
    arm_pid=$(cat "$FM_TEST_ARM_PID_FILE" 2>/dev/null || true)
    [ -n "$arm_pid" ] && kill -TERM "$arm_pid" 2>/dev/null || true
    ;;
esac
exec /bin/ln "$@"
SH
  chmod +x "$fakebin/ln"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_TEST_ARM_PID_FILE="$pidfile" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  printf '%s\n' "$armpid" > "$pidfile"
  i=0
  while [ "$i" -lt 100 ] && is_live_non_zombie "$armpid"; do
    [ -e "$state/.watch.lock.steal" ] && break
    sleep 0.02
    i=$((i + 1))
  done
  status=0
  wait_for_exit "$armpid" 150 || status=$?
  [ "$status" -eq 143 ] || fail "arm did not finish with TERM after stale-lock recovery (status $status)"
  [ ! -e "$state/.watch.lock.steal" ] && [ ! -L "$state/.watch.lock.steal" ] \
    || fail "TERM during startup left the steal marker behind"
  pass "arm defers TERM until startup watcher can run its lock cleanup"
}

test_arm_term_bounds_wait_for_stalled_startup() {
  local dir state fakebin armout pidfile release armpid i status
  dir=$(make_case arm-term-stalled-startup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  pidfile="$dir/arm.pid"
  release="$dir/release"
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
last=
for arg do last=$arg; done
case "$last" in
  */.watch.lock)
    i=0
    while [ "$i" -lt 100 ] && [ ! -s "$FM_TEST_ARM_PID_FILE" ]; do
      sleep 0.02
      i=$((i + 1))
    done
    kill -TERM "$(cat "$FM_TEST_ARM_PID_FILE")" 2>/dev/null || true
    while [ ! -e "$FM_TEST_RELEASE" ]; do sleep 0.05; done
    ;;
esac
exec /bin/ln "$@"
SH
  chmod +x "$fakebin/ln"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_TEST_ARM_PID_FILE="$pidfile" FM_TEST_RELEASE="$release" \
    FM_ARM_CONFIRM_TIMEOUT=2 FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  printf '%s\n' "$armpid" > "$pidfile"
  i=0
  while [ "$i" -lt 100 ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$armpid"; then
    : > "$release"
    wait_for_exit "$armpid" 50 >/dev/null 2>&1 || true
    fail "arm TERM waited past the confirmation deadline for a stalled startup"
  fi
  : > "$release"
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -eq 143 ] || fail "arm did not finish with TERM after a stalled startup (status $status)"
  pass "arm TERM stops a startup watcher that never becomes cleanup-ready"
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

test_pid_identity_is_terminal_width_invariant() {
  # The portable fallback records its identity from a wide shell (the arm or
  # watcher process) but re-reads it inside a narrow-COLUMNS hook, where ps cuts
  # the command column to the ambient width unless the fallback pins COLUMNS wide.
  # A truncated command then never equals the recorded one and every fleet command
  # is denied (issue #799). A long sleep argument makes the cut visible on GNU and
  # BSD ps alike, so both readings must be byte-identical and carry the whole command.
  local live no_proc narrow wide
  local long_arg=300.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
  no_proc="$TMP_ROOT/no-width-proc"
  if ! LC_ALL=C ps -p "$$" -o lstart= -o command= >/dev/null 2>&1; then
    pass "terminal-width check skipped where ps -o lstart= is unsupported"
    return
  fi
  sleep "$long_arg" &
  live=$!
  narrow=$(COLUMNS=20 FM_PROC_ROOT_OVERRIDE="$no_proc" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  wide=$(COLUMNS=1000 FM_PROC_ROOT_OVERRIDE="$no_proc" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$wide" ] || fail "fm_pid_identity produced no identity under a wide COLUMNS"
  case "$wide" in
    *"sleep $long_arg"*) ;;
    *) fail "fm_pid_identity dropped the full command under a wide COLUMNS (got '$wide')" ;;
  esac
  [ "$narrow" = "$wide" ] || fail "fm_pid_identity varied with COLUMNS (narrow '$narrow', wide '$wide')"
  pass "fm_pid_identity ps fallback is terminal-width-invariant"
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

test_wait_deadline_reaps_a_stopped_child
test_singleton_start
test_pid_identity_is_locale_invariant
test_pid_identity_is_terminal_width_invariant
test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse
test_msys_pid_identity_uses_proc
test_stale_watch_lock_reclaimed
test_stale_watch_reclaim_publishes_before_clear
test_live_stale_watch_lock_is_actionable
test_live_stalled_watch_lock_is_replaced_past_hard_bound
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_reclaims_dead_steal_owner_without_nested_markers
test_lock_recovers_dead_nested_steal_chain
test_lock_steal_reap_cannot_remove_successor
test_lock_reclaims_self_held_steal_mutex
test_lock_resumes_own_interrupted_steal_reap
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_direct_directory_reaper_cannot_remove_live_successor
test_direct_directory_lock_release_and_reap
test_link_mode_layout_is_unchanged
test_link_mode_removal_is_unchanged
test_lock_without_real_symlinks
test_directory_lock_single_winner_under_load
test_dirlock_identity_cases_per_shell
test_dirlock_d1b_failed_claim_leaves_generation_to_retirement
test_dirlock_d4_crashed_release_is_finished
test_dirlock_d4b_handoff_release_recovers_caller
test_dirlock_d4c_orphan_husk_cleanup_preserves_successor
test_dirlock_d5_orphan_retirement_cannot_touch_successor
test_dirlock_d5b_stealer_retires_only_captured_generation
test_dirlock_d5c_acquirer_retires_captured_generation
test_dirlock_d6_late_publication_is_ordinary_recovery
test_dirlock_d7b_bounded_helper_killed_by_deadline
test_dirlock_d8_dead_steal_mutex_observers_compose
test_dirlock_d8b_reaper_retires_captured_generation
test_dirlock_d9_uncommitted_retirement_keeps_record
test_dirlock_d10_committed_retirement_is_finished
test_dirlock_d11_ambiguous_generation_is_refused
test_dirlock_d11b_dead_ambiguous_generation_is_refused
test_dirlock_d12_staging_litter_is_never_consulted
test_lock_reclaims_reused_pid_lock
test_lock_respects_live_holder_matching_its_start_time
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
test_arm_term_during_steal_waits_for_watcher_cleanup_trap
test_arm_term_bounds_wait_for_stalled_startup
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
