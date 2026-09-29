#!/usr/bin/env bash
# Portable behavior tests for bin/fm-primary-doorbell.sh, the watcher arm owner
# for a Kiro doorbell primary. A copied Bash executable named kiro-cli owns the
# fleet lock and publishes the real endpoint record; a thin tmux fake serves one
# Kiro composer and logs every typed key; a stub bin/fm-watch-arm.sh records
# each cycle it starts and closes on demand. No model or live harness is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-doorbell)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cp "$(command -v bash)" "$FAKEBIN/kiro-cli"
chmod +x "$FAKEBIN/kiro-cli"
EXTRA_PIDS=()

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '1\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    cat "$FM_PRIMARY_TEST_SCREEN"
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_PRIMARY_TEST_SEND_LOG"
    printf 'ring %s\n' "$*" >> "$FM_PRIMARY_TEST_EVENTS"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

cat > "$TMP_ROOT/stub-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
dir=$FM_DOORBELL_TEST_DIR
if [ "${1:-}" = --handling-delivered ]; then
  printf 'handoff %s %s\n' "$2" "$4" >> "$dir/events.log"
  exit "$(cat "$dir/handoff-rc" 2>/dev/null || echo 0)"
fi
n=$(( $(cat "$dir/arm-count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$dir/arm-count"
printf 'start n=%s pid=%s pred=%s\n' "$n" "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$dir/events.log"
trap 'printf "term n=%s\n" "$n" >> "$dir/events.log"; exit 143' TERM
behavior=$(cat "$dir/arm-behavior" 2>/dev/null || echo ok)
if [ "$behavior" = fail ]; then
  echo 'watcher: FAILED - stub'
  exit 1
fi
if [ "$behavior" = stubborn ]; then
  trap 'printf "ignored-term n=%s\n" "$n" >> "$dir/events.log"' TERM
fi
# A successor names watcher-pid when the case wrote one (a watcher already gone).
watcher=$$
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] && [ -f "$dir/watcher-pid" ]; then
  watcher=$(cat "$dir/watcher-pid")
fi
line="watcher: started pid=$watcher (beacon fresh)"
[ -z "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] || line="$line recovery-generation=gen$n"
printf '%s\n' "$line"
while [ ! -f "$dir/close.$n" ]; do sleep 0.1; done
cat "$dir/close.$n"
exit 0
SH
chmod +x "$TMP_ROOT/stub-arm.sh"

# A stub supervision host for opted-in cases: it records how the owner started
# it, prints the arm's status line (or stands down when host-behavior.<n> says
# so), and closes with the contents of hclose.<n>; with behavior `die` it
# kills itself with SIGKILL once hdie.<n> exists.
cat > "$TMP_ROOT/stub-host.sh" <<'SH'
#!/usr/bin/env bash
set -u
dir=$FM_DOORBELL_TEST_DIR
n=$(( $(cat "$dir/host-count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$dir/host-count"
printf 'host-start n=%s pid=%s primary=%s served=%s args=%s pred=%s\n' "$n" "$$" \
  "${FM_SUPERVISION_HOST_PRIMARY:-}" "${FM_SUPERVISION_HOST_SERVED_PID:-}" "$*" \
  "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$dir/events.log"
trap 'printf "host-term n=%s\n" "$n" >> "$dir/events.log"; exit 143' TERM
if [ "$(cat "$dir/host-behavior.$n" 2>/dev/null)" = standdown ]; then
  echo 'supervision-host stood down: test'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while [ ! -f "$dir/hclose.$n" ]; do
  if [ -f "$dir/hdie.$n" ] && [ "$(cat "$dir/host-behavior.$n" 2>/dev/null)" = die ]; then
    kill -KILL "$$"
  fi
  sleep 0.1
done
cat "$dir/hclose.$n"
exit 0
SH
chmod +x "$TMP_ROOT/stub-host.sh"

# Kill every process whose command line names this run's fixture tree: owners,
# stub arms, and fake kiro-cli sessions.
reap_all() {
  local pid
  for pid in $(pgrep -f "$TMP_ROOT" 2>/dev/null || true); do
    [ "$pid" = "$$" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${EXTRA_PIDS[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 0.3
  for pid in $(pgrep -f "$TMP_ROOT" 2>/dev/null || true); do
    [ "$pid" = "$$" ] || kill -KILL "$pid" 2>/dev/null || true
  done
}
trap 'reap_all; fm_test_cleanup' EXIT

wait_for() {  # <description> <timeout-seconds> <command...>
  local desc=$1 limit i=0
  limit=$(awk -v s="$2" 'BEGIN { print int(s * 10) }')
  shift 2
  while ! "$@"; do
    i=$((i + 1))
    [ "$i" -lt "$limit" ] || fail "timed out after ${limit}ds waiting for: $desc"
    sleep 0.1
  done
}

# Holds for <seconds>, failing if <command> ever succeeds.
never_for() {  # <description> <seconds> <command...>
  local desc=$1 limit i=0
  limit=$(awk -v s="$2" 'BEGIN { print int(s * 10) }')
  shift 2
  while [ "$i" -lt "$limit" ]; do
    ! "$@" || fail "$desc"
    sleep 0.1
    i=$((i + 1))
  done
}

# Case globals: D case dir, R code root, H home, S state.
D='' R='' H='' S=''
new_case() {  # <name>
  D="$TMP_ROOT/$1"; R="$D/root"; H="$D/home"; S="$H/state"
  mkdir -p "$S" "$R"
  cp -R "$ROOT/bin" "$R/bin"
  printf '# Firstmate\n' > "$R/AGENTS.md"
  cp "$TMP_ROOT/stub-arm.sh" "$R/bin/fm-watch-arm.sh"
  : > "$S/t1.meta"
  : > "$D/events.log"
  : > "$D/send.log"
  printf 'transcript\n\033[38;2;158;158;158m› ask a question or describe a task ↵\033[0m\n' > "$D/idle.screen"
  printf 'transcript\n› half typed command\n' > "$D/pending.screen"
  screen idle
}

screen() { cp "$D/$1.screen" "$D/screen"; }

in_case() {  # <command...>  run with this case's environment
  PATH="$FAKEBIN:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_ROOT_OVERRIDE="$R" \
    TMUX_PANE=primary:0 FM_DOORBELL_TEST_DIR="$D" \
    FM_PRIMARY_TEST_SCREEN="$D/screen" FM_PRIMARY_TEST_SEND_LOG="$D/send.log" \
    FM_PRIMARY_TEST_EVENTS="$D/events.log" \
    FM_PRIMARY_DOORBELL_POLL=0.2 FM_PRIMARY_DOORBELL_READY_TIMEOUT=5 "$@"
}

doorbell() { in_case "$R/bin/fm-primary-doorbell.sh" "$@"; }

start_kiro() {
  # shellcheck disable=SC2016 # Expanded by the fake kiro-cli shell.
  (
    export PATH="$FAKEBIN:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_ROOT_OVERRIDE="$R" \
      TMUX_PANE=primary:0 FM_PRIMARY_TEST_SCREEN="$D/screen"
    exec "$FAKEBIN/kiro-cli" -c '
    printf "%s\n" "$$" > "$FM_STATE_OVERRIDE/.lock"
    . "$FM_ROOT_OVERRIDE/bin/fm-primary-endpoint-lib.sh"
    fm_primary_endpoint_publish "$FM_STATE_OVERRIDE" "$FM_ROOT_OVERRIDE" "$FM_HOME" || exit 9
    while :; do sleep 1; done'
  ) </dev/null >"$D/kiro.out" 2>&1 &
  printf '%s\n' "$!" > "$D/kiro.pid"
  wait_for "the fake Kiro session publishes its endpoint" 5 test -f "$S/.primary-endpoint"
}

owner_pid() { cat "$S/.primary-doorbell.lock/pid" 2>/dev/null; }

gone() {  # <pid>  dead or a zombie
  local st
  st=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
  case "$st" in Z*) return 0 ;; esac
  return 1
}

events_has() { grep -q -- "$1" "$D/events.log"; }
count() { grep -c -- "$1" "$D/events.log" || true; }
wake_rings() { count ': Firstmate wake waiting:'; }
rings_at_least() { [ "$(wake_rings)" -ge "$1" ]; }
rang_twice() {
  rings_at_least 2 || return 1
  { cat "$D/events.log"; echo "queue:"; cat "$S/.wake-queue"; ls -la "$S"; } >&2
}
arm_n() { cat "$D/arm-count" 2>/dev/null || echo 0; }
arm_pid() { sed -n "s/^start n=$1 pid=\([0-9]*\) .*/\1/p" "$D/events.log"; }

append_row() {
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  in_case bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; fm_wake_append signal t1 "signal: t1"' \
    || fail "could not append a wake queue row"
}

close_arm() {  # <n> <reason>
  printf '%s\n' "$2" > "$D/close.$1.tmp" && mv "$D/close.$1.tmp" "$D/close.$1"
}

start_owner() {
  local out
  out=$(doorbell ensure) || fail "ensure failed: $out"
  wait_for "the first arm starts" 5 events_has 'start n=1 '
}

end_case() {
  local pid
  for pid in $(pgrep -f "$D/" 2>/dev/null || true); do kill -TERM "$pid" 2>/dev/null || true; done
  if [ -f "$D/kiro.pid" ]; then
    pid=$(cat "$D/kiro.pid")
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  wait_for "case $D leaves no process behind" 5 no_case_procs
}
no_case_procs() { ! pgrep -f "$D/" >/dev/null 2>&1; }

line_of() { grep -n -m1 -- "$1" "$D/events.log" | cut -d: -f1; }

test_ensure_starts_exactly_one_owner() {
  local out rc pid o1 o2 p1 p2
  new_case single
  start_kiro
  out=$(doorbell ensure); rc=$?
  [ "$rc" = 0 ] || fail "first ensure exited $rc: $out"
  case "$out" in "doorbell-owner: started pid="[0-9]*) ;; *) fail "first ensure printed '$out'" ;; esac
  pid=${out#doorbell-owner: started pid=}
  out=$(doorbell ensure); rc=$?
  [ "$rc" = 0 ] || fail "second ensure exited $rc: $out"
  assert_equals "$out" "doorbell-owner: running pid=$pid" "second ensure did not report the running owner"
  end_case

  new_case concurrent
  start_kiro
  doorbell ensure > "$D/o1" & p1=$!
  doorbell ensure > "$D/o2" & p2=$!
  wait "$p1" || fail "concurrent ensure 1 failed: $(cat "$D/o1")"
  wait "$p2" || fail "concurrent ensure 2 failed: $(cat "$D/o2")"
  o1=$(cat "$D/o1"); o2=$(cat "$D/o2")
  pid=$(owner_pid)
  assert_contains "$o1" "pid=$pid" "concurrent ensure 1 names another owner: $o1"
  assert_contains "$o2" "pid=$pid" "concurrent ensure 2 names another owner: $o2"
  wait_for "the first arm starts" 5 events_has 'start n=1 '
  one_owner() { [ "$(pgrep -fc "$R/bin/fm-primary-doorbell.sh run")" = 1 ]; }
  wait_for "exactly one owner process remains" 5 one_owner
  sleep 0.5
  assert_equals "$(count '^start n=')" 1 "concurrent ensures started more than one first cycle"
  end_case
  pass "doorbell owner: ensure starts exactly one owner, reports it when running, and concurrent ensures converge on one"
}

test_close_starts_successor_before_ring() {
  local a1 a2 s h r
  new_case successor
  start_kiro
  start_owner
  a1=$(arm_pid 1)
  append_row
  close_arm 1 'signal: t1'
  wait_for "the doorbell rings" 5 rings_at_least 1
  a2=$(arm_pid 2)
  [ -n "$a2" ] || fail "no successor arm started: $(cat "$D/events.log")"
  s=$(line_of "^start n=2 pid=$a2 pred=$a1\$")
  h=$(line_of "^handoff gen2 $a2\$")
  r=$(line_of '^ring ')
  [ -n "$s" ] && [ -n "$h" ] && [ -n "$r" ] && [ "$s" -lt "$h" ] && [ "$h" -lt "$r" ] \
    || fail "close order is not successor, handoff, ring: $(cat "$D/events.log")"
  assert_equals "$(wake_rings)" 1 "an actionable close rang more than once"
  sleep 0.6
  assert_equals "$(wake_rings)" 1 "the owner rang again for an already-rung close"
  end_case
  pass "doorbell owner: an actionable close starts the handling successor and confirms it before one ring"
}

test_busy_pane_defers_and_handled_wake_drops() {
  local n
  new_case busy
  start_kiro
  start_owner
  screen pending
  append_row
  close_arm 1 'signal: t1'
  wait_for "the successor starts" 5 events_has '^start n=2 '
  never_for "the owner rang into a busy composer" 1 rings_at_least 1
  screen idle
  wait_for "the deferred ring lands once the pane is idle" 5 rings_at_least 1
  sleep 0.5
  assert_equals "$(wake_rings)" 1 "the deferred close rang more than once"

  screen pending
  append_row
  n=$(arm_n)
  close_arm "$n" 'signal: t1'
  wait_for "the next successor starts" 5 events_has "^start n=$((n + 1)) "
  # The primary handled it: the drain empties the queue and settles the
  # downtime episode an append made with no real watcher holding its lock.
  : > "$S/.wake-queue"
  rm -f "$S/.watcher-down"
  # Let a poll already past its pending check finish against the busy pane.
  sleep 0.5
  screen idle
  never_for "the owner rang for a wake the primary already handled" 1.5 rang_twice
  end_case
  pass "doorbell owner: a busy pane defers the ring and a wake handled meanwhile drops it"
}

test_recovery_episode_rings_with_empty_queue() {
  new_case recovery
  start_kiro
  start_owner
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  in_case bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; fm_recovery_marker_publish "$FM_STATE_OVERRIDE/.watcher-down"' \
    || fail "could not publish a recovery marker"
  close_arm 1 'check: rearm-resurface'
  wait_for "the recovery episode rings" 5 rings_at_least 1
  sleep 0.5
  assert_equals "$(wake_rings)" 1 "the recovery episode rang more than once"
  end_case
  pass "doorbell owner: an unacknowledged recovery episode rings even with an empty queue"
}

test_owner_stands_down_when_lock_moves() {
  local pid other n
  new_case lockmove
  start_kiro
  start_owner
  pid=$(owner_pid)
  n=$(arm_n)
  sleep 60 & other=$!
  EXTRA_PIDS+=("$other")
  printf '%s\n' "$other" > "$S/.lock"
  wait_for "the owner exits after the lock moves" 3 gone "$pid"
  wait_for "the owner stops its arm" 3 events_has "^term n=$n\$"
  assert_absent "$S/.primary-doorbell.lock" "the owner left its lock behind"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  end_case
  pass "doorbell owner: stands down, stops its arm, and releases its lock when the fleet lock moves"
}

test_away_mode_stands_down() {
  local pid n out rc
  new_case away
  start_kiro
  start_owner
  pid=$(owner_pid)
  n=$(arm_n)
  touch "$S/.afk"
  wait_for "the owner exits in away mode" 3 gone "$pid"
  wait_for "the owner stops its arm" 3 events_has "^term n=$n\$"
  out=$(doorbell ensure); rc=$?
  assert_equals "$rc" 0 "ensure in away mode exited nonzero"
  assert_equals "$out" "doorbell-owner: away mode" "ensure in away mode printed the wrong line"
  end_case
  pass "doorbell owner: away mode stops the owner and its arm, and ensure defers to the away daemon"
}

test_no_need_after_close_rings_and_exits() {
  local pid
  new_case noneed
  start_kiro
  start_owner
  pid=$(owner_pid)
  rm -f "$S/t1.meta"
  append_row
  close_arm 1 'signal: t1'
  wait_for "the final close rings" 5 rings_at_least 1
  wait_for "the owner exits once supervision is not needed" 5 gone "$pid"
  assert_equals "$(wake_rings)" 1 "the final close rang more than once"
  assert_equals "$(count '^start n=')" 1 "the owner started a cycle nobody needs"
  end_case
  pass "doorbell owner: a close after the fleet empties rings once and exits without a successor"
}

test_repeated_arm_failure_rings_once_and_cools_down() {
  local pid out rc
  new_case failing
  printf 'fail\n' > "$D/arm-behavior"
  start_kiro
  out=$(FM_PRIMARY_DOORBELL_RETRY_LIMIT=2 doorbell ensure) || fail "ensure failed: $out"
  pid=${out##*pid=}
  failure_rang() { [ "$(count ': Firstmate watcher continuity FAILED:')" -ge 1 ]; }
  wait_for "the continuity failure rings" 15 failure_rang
  wait_for "the owner exits after the failure ring" 5 gone "$pid"
  assert_equals "$(count ': Firstmate watcher continuity FAILED:')" 1 "the continuity failure rang more than once"
  assert_present "$S/.primary-doorbell-failed" "no continuity failure record was written"
  out=$(doorbell ensure); rc=$?
  assert_equals "$rc" 4 "ensure during the failure cooldown did not exit 4: $out"
  case "$out" in "doorbell-owner: cooling down"*) ;; *) fail "ensure during cooldown printed '$out'" ;; esac
  end_case
  pass "doorbell owner: repeated arm failure records itself, rings one continuity failure, exits, and cools down"
}

test_no_endpoint_is_unavailable() {
  local out rc
  new_case noendpoint
  out=$(doorbell ensure); rc=$?
  assert_equals "$rc" 3 "ensure without an endpoint did not exit 3: $out"
  case "$out" in "doorbell-owner: unavailable"*) ;; *) fail "ensure without an endpoint printed '$out'" ;; esac
  assert_absent "$S/.primary-doorbell.lock" "ensure without an endpoint took an owner lock"
  end_case
  pass "doorbell owner: ensure without a loadable endpoint reports unavailable and starts nothing"
}

test_not_needed_starts_nothing() {
  local out rc
  new_case notneeded
  rm -f "$S/t1.meta"
  start_kiro
  out=$(doorbell ensure); rc=$?
  assert_equals "$rc" 0 "ensure with no supervision need exited nonzero"
  assert_equals "$out" "doorbell-owner: not needed" "ensure with no supervision need printed the wrong line"
  assert_absent "$S/.primary-doorbell.lock" "ensure with no supervision need took an owner lock"
  sleep 0.3
  assert_equals "$(count '^start n=')" 0 "ensure with no supervision need started an arm"
  end_case
  pass "doorbell owner: ensure with no supervision need starts nothing"
}

test_reused_pid_lock_is_reclaimed() {
  local old other out rc new
  new_case reusedpid
  start_kiro
  start_owner
  old=$(owner_pid)
  # The owner dies without cleanup, so its lock (pid + pid-identity) stays.
  kill -KILL "$old" 2>/dev/null || true
  kill -KILL "$(arm_pid 1)" 2>/dev/null || true
  wait_for "the killed owner is gone" 3 gone "$old"
  assert_present "$S/.primary-doorbell.lock/pid-identity" "the killed owner's lock did not survive"
  # Its pid is reused by an unrelated live process; the recorded identity stays.
  sleep 60 & other=$!
  EXTRA_PIDS+=("$other")
  printf '%s\n' "$other" > "$S/.primary-doorbell.lock/pid"
  out=$(doorbell ensure); rc=$?
  assert_equals "$rc" 0 "ensure over a reused-pid lock exited $rc: $out"
  case "$out" in "doorbell-owner: started pid="[0-9]*) ;; *) fail "ensure over a reused-pid lock printed '$out'" ;; esac
  new=${out#doorbell-owner: started pid=}
  [ "$new" != "$other" ] && [ "$new" != "$old" ] || fail "ensure named a stale owner pid $new"
  assert_equals "$(owner_pid)" "$new" "the new owner does not hold the lock"
  ! gone "$new" || fail "the new owner is not alive"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  end_case
  pass "doorbell owner: a lock whose live pid no longer matches its recorded identity is reclaimed by a new owner"
}

test_term_resistant_arm_is_killed_on_stand_down() {
  local pid arm other
  new_case stubborn
  printf 'stubborn\n' > "$D/arm-behavior"
  start_kiro
  start_owner
  pid=$(owner_pid)
  arm=$(arm_pid 1)
  sleep 60 & other=$!
  EXTRA_PIDS+=("$other")
  printf '%s\n' "$other" > "$S/.lock"
  wait_for "the owner exits despite a TERM-resistant arm" 8 gone "$pid"
  wait_for "the TERM-resistant arm is killed" 2 gone "$arm"
  events_has '^ignored-term n=1$' || fail "the owner never sent TERM before KILL: $(cat "$D/events.log")"
  assert_absent "$S/.primary-doorbell.lock" "the owner left its lock behind"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  end_case
  pass "doorbell owner: a TERM-resistant arm is KILLed after the grace and the owner still stands down"
}

test_refused_handoff_with_dead_watcher_is_a_failed_start() {
  local dead h s
  new_case deadhandoff
  printf '1\n' > "$D/handoff-rc"
  true & dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$D/watcher-pid"
  start_kiro
  start_owner
  append_row
  close_arm 1 'signal: t1'
  wait_for "a fresh cycle starts after the refused handoff" 10 events_has '^start n=3 '
  assert_equals "$(count "^handoff gen2 $dead\$")" 2 "the refused handoff was not retried exactly once"
  h=$(grep -n "^handoff gen2 " "$D/events.log" | tail -1 | cut -d: -f1)
  s=$(line_of '^start n=3 ')
  [ "$s" -gt "$h" ] || fail "the retry cycle did not follow the refused handoff: $(cat "$D/events.log")"
  events_has '^term n=2$' || fail "the owner did not stop the unconfirmed successor: $(cat "$D/events.log")"
  wait_for "the pending wake still rings" 5 rings_at_least 1
  sleep 0.6
  assert_equals "$(wake_rings)" 1 "the pending wake did not ring exactly once"
  end_case
  pass "doorbell owner: a handoff refused twice while the successor's watcher is gone is a failed start that retries and still rings once"
}

# A running watcher can queue a row without closing, for example a process
# result it republishes after surfacing it once. The owner still rings once for
# the newest row no ring covered, and once more only for a newer row.
test_row_without_close_rings_once() {
  new_case rowonly
  start_kiro
  start_owner
  append_row
  wait_for "a row queued without a close rings" 5 rings_at_least 1
  never_for "the owner rang again for a row it already rang" 1 rings_at_least 2
  append_row
  wait_for "a newer row rings once more" 5 rings_at_least 2
  never_for "the owner rang a third time for two rows" 1 rings_at_least 3
  assert_equals "$(count '^start n=')" 1 "a row without a close started another cycle"
  end_case
  pass "doorbell owner: a row queued without a close rings once, and a newer row rings once more"
}

# ---- supervision host (config/supervision-host) ------------------------------

opt_in_host() {
  cp "$TMP_ROOT/stub-host.sh" "$R/bin/fm-supervision-host.sh"
  mkdir -p "$H/config"
  : > "$H/config/supervision-host"
}

start_host_owner() {
  local out
  out=$(doorbell ensure) || fail "ensure failed: $out"
  wait_for "the first host starts" 5 events_has '^host-start n=1 '
}

close_host() {  # <n> <content>
  printf '%s\n' "$2" > "$D/hclose.$1.tmp" && mv "$D/hclose.$1.tmp" "$D/hclose.$1"
}

test_opted_in_owner_runs_the_host_in_the_arms_place() {
  local served
  new_case hoststart
  opt_in_host
  start_kiro
  served=$(cat "$S/.lock")
  start_host_owner
  events_has "^host-start n=1 pid=[0-9]* primary=kiro-cli served=$served args=park pred=none\$" \
    || fail "the host did not start as a kiro-cli park serving pid $served: $(cat "$D/events.log")"
  sleep 0.5
  assert_equals "$(count '^start n=')" 0 "an opted-in owner started the watcher arm"
  end_case
  pass "doorbell owner: an opted-in home runs the supervision host park (primary kiro-cli, served lock pid) instead of the arm"
}

test_host_close_rings_with_an_empty_queue_and_writes_the_note() {
  local s r
  new_case hostclose
  opt_in_host
  start_kiro
  start_host_owner
  [ ! -s "$S/.wake-queue" ] || fail "fixture: the queue is not empty"
  close_host 1 'supervision-host: cycle boundary test'
  wait_for "the host close rings" 5 rings_at_least 1
  wait_for "the next host cycle starts" 5 events_has '^host-start n=2 '
  never_for "a host close rang more than once" 1 rings_at_least 2
  s=$(line_of '^host-start n=2 ')
  r=$(line_of '^ring ')
  [ "$s" -lt "$r" ] || fail "the next host did not start before the ring: $(cat "$D/events.log")"
  assert_present "$S/.primary-doorbell-note" "the host close left no doorbell note"
  assert_grep 'supervision-host: cycle boundary test' "$S/.primary-doorbell-note" "the note lacks the host line"
  assert_no_grep 'watcher: started' "$S/.primary-doorbell-note" "the note kept the arm's status line"
  end_case
  pass "doorbell owner: a host close with a supervision-host line rings once on an empty queue, notes the close without its status line, and starts the next host"
}

test_host_stand_down_is_a_failed_start() {
  new_case hoststanddown
  opt_in_host
  printf 'standdown\n' > "$D/host-behavior.1"
  start_kiro
  start_host_owner
  wait_for "a stood-down host is retried" 8 events_has '^host-start n=2 '
  never_for "a stood-down host rang the primary" 1 rings_at_least 1
  assert_absent "$S/.primary-doorbell-note" "a stood-down host wrote a doorbell note"
  assert_equals "$(count '^start n=')" 0 "a stood-down host fell back to the arm"
  end_case
  pass "doorbell owner: a host that stands down is a failed start that retries without ringing"
}

test_host_owns_rows_while_it_runs() {
  local posture
  for posture in away attended; do
    new_case "hostrows-$posture"
    opt_in_host
    start_kiro
    start_host_owner
    [ "$posture" = attended ] || printf 'words=watch\n' > "$S/.afk-contract"
    append_row
    never_for "a row rang while the $posture host may still offer it to its engine" 3 rings_at_least 1
    end_case
  done
  pass "doorbell owner: while an opted-in host runs, attended or away, it owns queued rows and no row-only ring fires"
}

test_host_death_rings_its_queued_rows() {
  new_case hostdeath
  opt_in_host
  printf 'die\n' > "$D/host-behavior.1"
  start_kiro
  start_host_owner
  append_row
  never_for "a row rang while the host was alive" 2 rings_at_least 1
  : > "$D/hdie.1"
  wait_for "a dead host's queued row reaches main" 8 rings_at_least 1
  wait_for "a dead host is replaced" 8 events_has '^host-start n=2 '
  never_for "a dead host's row rang more than once" 1 rings_at_least 2
  end_case
  pass "doorbell owner: a host that dies is replaced, and the main rows it held are rung once"
}

test_opted_in_owner_runs_the_host_in_the_arms_place
test_host_close_rings_with_an_empty_queue_and_writes_the_note
test_host_stand_down_is_a_failed_start
test_host_owns_rows_while_it_runs
test_host_death_rings_its_queued_rows
test_ensure_starts_exactly_one_owner
test_row_without_close_rings_once
test_reused_pid_lock_is_reclaimed
test_term_resistant_arm_is_killed_on_stand_down
test_refused_handoff_with_dead_watcher_is_a_failed_start
test_close_starts_successor_before_ring
test_busy_pane_defers_and_handled_wake_drops
test_recovery_episode_rings_with_empty_queue
test_owner_stands_down_when_lock_moves
test_away_mode_stands_down
test_no_need_after_close_rings_and_exits
test_repeated_arm_failure_rings_once_and_cools_down
test_no_endpoint_is_unavailable
test_not_needed_starts_nothing

leftover=$(pgrep -f "$TMP_ROOT" 2>/dev/null | grep -vx "$$" || true)
[ -z "$leftover" ] || fail "processes left behind: $(ps -o pid=,args= -p "$(printf '%s' "$leftover" | tr '\n' ,)")"
