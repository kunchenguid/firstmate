#!/usr/bin/env bash
# Behavior tests for the wall-clock bound on remote calls the watcher makes.
#
# ssh keepalives only detect a dead peer: a remote command that is alive but
# stuck (a full disk, a wedged job worker) keeps sshd answering probes forever.
# These tests drive a fake ssh that blocks while "sshd stays up" and assert that
# the bounded call reports remote-unavailable (255) within its bound, that the
# host then backs off without spending another bound, that a real watcher cycle
# still runs its other checks, and that repeated timeouts wake firstmate once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-watch-remote-timeout)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# make_world <name>: a parent home with one remote secondmate route and a fake
# ssh that logs each call and then blocks, or answers when FM_FAKE_SSH_REPLY
# is set.
make_world() {
  local w="$TMP_ROOT/$1" fakebin
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  cat > "$w/home/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
if [ -n "${FM_FAKE_SSH_REPLY:-}" ]; then
  printf '%s\n' "$FM_FAKE_SSH_REPLY"
  exit 0
fi
# The connection stays up and the remote command never finishes.
exec sleep 30
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

ssh_calls() { [ -f "$1/ssh.log" ] && wc -l < "$1/ssh.log" | tr -d ' ' || echo 0; }

# on <w> [env...] -- <fm-on args...>: run fm-on.sh against the world.
on() {
  local w=$1; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env FM_HOME="$w/home" FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" \
    ${envs[@]+"${envs[@]}"} bash "$ROOT/bin/fm-on.sh" "$@" < /dev/null
}

test_bounded_call_times_out_as_unavailable() {
  local w rc=0 start elapsed err
  w=$(make_world bounded)
  err="$w/err"
  start=$(date +%s)
  on "$w" FM_REMOTE_CALL_TIMEOUT=2 -- --bounded rsm1 fm-remote-secondmate-control.sh state rsm1 \
    > /dev/null 2> "$err" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -eq 255 ] || fail "a timed-out remote call must report unavailable (255), got $rc: $(cat "$err")"
  [ "$elapsed" -lt 10 ] || fail "a 2s bound let the blocked remote call run ${elapsed}s"
  grep -F 'lab-host' "$err" | grep -F 'fm-remote-secondmate-control.sh state' >/dev/null \
    || fail "the timeout diagnostic must name the host and the stuck command: $(cat "$err")"
  pass "a bounded remote call that blocks returns 255 within its bound"
}

test_timed_out_host_backs_off_without_another_bound() {
  local w rc=0 start elapsed
  w=$(make_world backoff)
  on "$w" FM_REMOTE_CALL_TIMEOUT=2 -- --bounded rsm1 fm-remote-secondmate-control.sh state rsm1 \
    > /dev/null 2>&1 || true
  [ "$(ssh_calls "$w")" = 1 ] || fail "expected one ssh call before backoff"
  start=$(date +%s)
  on "$w" FM_REMOTE_CALL_TIMEOUT=2 -- --bounded rsm1 fm-remote-secondmate-control.sh observe rsm1 \
    > /dev/null 2> "$w/err" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -eq 255 ] || fail "a backing-off host must report unavailable (255), got $rc"
  [ "$elapsed" -lt 2 ] || fail "a backing-off host spent ${elapsed}s instead of failing at once"
  [ "$(ssh_calls "$w")" = 1 ] || fail "a backing-off host must not be dialed again: $(cat "$w/ssh.log")"
  grep -F 'lab-host' "$w/err" >/dev/null || fail "the backoff diagnostic must name the host: $(cat "$w/err")"

  # An unbounded caller keeps today's behavior and is never short-circuited.
  rc=0
  on "$w" FM_FAKE_SSH_REPLY=alive -- rsm1 fm-remote-secondmate-control.sh state rsm1 > "$w/out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$w/out")" = alive ] \
    || fail "an unbounded call must not be refused by another caller's backoff: rc=$rc $(cat "$w/out")"

  # Once the backoff has elapsed, a completed call ends the timeout streak.
  rc=0
  on "$w" FM_REMOTE_CALL_TIMEOUT=2 FM_REMOTE_CALL_BACKOFF=0 FM_FAKE_SSH_REPLY=alive -- \
    --bounded rsm1 fm-remote-secondmate-control.sh state rsm1 > "$w/out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$w/out")" = alive ] || fail "a recovered host should answer: rc=$rc $(cat "$w/out")"
  rc=0
  on "$w" FM_REMOTE_CALL_TIMEOUT=2 FM_FAKE_SSH_REPLY=alive -- \
    --bounded rsm1 fm-remote-secondmate-control.sh state rsm1 > "$w/out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a completed call must clear the host's backoff, got $rc: $(cat "$w/out")"
  pass "a timed-out host backs off at once for bounded callers and clears on completion"
}

# A real watcher cycle with a remote secondmate whose remote command blocks
# must still reach an unrelated custom check within the bound.
test_watcher_cycle_is_not_stalled_by_a_blocked_remote() {
  local w pid i=0 start elapsed
  w=$(make_world watcher)
  cat > "$w/home/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
  cat > "$w/home/state/merge.check.sh" <<'SH'
#!/usr/bin/env bash
echo 'unrelated check ran'
SH
  chmod 700 "$w/home/state/merge.check.sh"
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" bash "$ROOT/bin/fm-check-register.sh" merge \
    > /dev/null || fail "could not register the unrelated custom check"
  touch "$w/home/state/home-summary.json"
  fm_test_track_watcher_state "$w/home/state"
  start=$(date +%s)
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_DATA_OVERRIDE="$w/home/data" FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" \
    FM_REMOTE_CALL_TIMEOUT=2 FM_POLL=1 \
    bash "$ROOT/bin/fm-watch.sh" > "$w/out" 2> "$w/err" &
  pid=$!
  while [ "$i" -lt 200 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  elapsed=$(( $(date +%s) - start ))
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher cycle stalled ${elapsed}s behind a blocked remote poll: $(cat "$w/err")"
  fi
  wait "$pid" 2>/dev/null || true
  [ "$(ssh_calls "$w")" -ge 1 ] || fail "the watcher never polled the remote mate, so the test proved nothing"
  grep -F 'unrelated check ran' "$w/out" >/dev/null \
    || fail "the unrelated check did not run in the cycle: out=$(cat "$w/out") err=$(cat "$w/err")"
  pass "a blocked remote poll cannot stall the watcher cycle's other checks"
}

test_repeated_timeouts_wake_once_naming_host_and_command() {
  local w n pid i
  w=$(make_world wake)
  for n in 1 2 3; do
    on "$w" FM_REMOTE_CALL_TIMEOUT=1 FM_REMOTE_CALL_BACKOFF=0 -- \
      --bounded rsm1 fm-remote-file.sh get data/r.md 10 > /dev/null 2>&1 || true
  done
  [ "$(ssh_calls "$w")" = 3 ] || fail "expected three timed-out calls, got $(ssh_calls "$w")"
  touch "$w/home/state/home-summary.json"
  fm_test_track_watcher_state "$w/home/state"
  for n in 1 2; do
    i=0
    FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" FM_CONFIG_OVERRIDE="$w/home/config" \
      FM_DATA_OVERRIDE="$w/home/data" FM_POLL=1 FM_REMOTE_CALL_WAKE_AFTER=3 \
      bash "$ROOT/bin/fm-watch.sh" > "$w/out.$n" 2> "$w/err.$n" &
    pid=$!
    while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  grep -F 'lab-host' "$w/out.1" | grep -F 'fm-remote-file.sh get' >/dev/null \
    || fail "three consecutive timeouts must wake naming host and command: $(cat "$w/out.1" "$w/err.1")"
  [ "$(grep -c 'remote-call-timeout' "$w/home/state/.wake-queue" 2>/dev/null)" = 1 ] \
    || fail "repeated timeouts must queue exactly one wake: $(cat "$w/home/state/.wake-queue" 2>/dev/null)"
  ! grep -F 'lab-host' "$w/out.2" >/dev/null \
    || fail "a second watcher cycle repeated the timeout wake: $(cat "$w/out.2")"
  pass "repeated timeouts queue one actionable wake naming the host and command"
}

# Several remote secondmates on different stuck hosts share one cycle's remote
# budget: per-host bounds alone would add up past the watcher's stale grace.
test_stuck_hosts_share_one_cycle_budget() {
  local w pid i=0 n first_call check_at spent
  w=$(make_world budget)
  : > "$w/home/data/secondmates.md"
  for n in 1 2 3 4; do
    printf -- '- rsm%s - Remote mate (host: host-%s; root: /remote/root; home: /remote/rsm%s-home; scope: remote work; projects: alpha; added 2026-01-01)\n' \
      "$n" "$n" "$n" >> "$w/home/data/secondmates.md"
    printf '%s\n' "window=remote:rsm$n" kind=secondmate harness=claude "remote_host=host-$n" \
      remote_backend=herdr remote_herdr_session=fm-remote remote_target=fm-remote:w1:p1 \
      "home=/remote/rsm$n-home" > "$w/home/state/rsm$n.meta"
  done
  # shellcheck disable=SC2016 # literal text for the fake ssh script
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s %s\n" "$(date +%s)" "$*" >> "${FM_FAKE_SSH_LOG:?}"' \
    'exec sleep 30' > "$w/fakebin/ssh"
  printf '%s\n' '#!/usr/bin/env bash' "date +%s > '$w/check-at'" "echo 'unrelated check ran'" \
    > "$w/home/state/merge.check.sh"
  chmod 700 "$w/home/state/merge.check.sh"
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" bash "$ROOT/bin/fm-check-register.sh" merge \
    > /dev/null || fail "could not register the unrelated custom check"
  touch "$w/home/state/home-summary.json"
  fm_test_track_watcher_state "$w/home/state"
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_DATA_OVERRIDE="$w/home/data" FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" \
    FM_REMOTE_CALL_TIMEOUT=3 FM_REMOTE_CALL_CYCLE_BUDGET=4 FM_POLL=1 \
    bash "$ROOT/bin/fm-watch.sh" > "$w/out" 2> "$w/err" &
  pid=$!
  while [ "$i" -lt 300 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -s "$w/ssh.log" ] || fail "the watcher never polled a remote mate, so the test proved nothing"
  grep -F 'unrelated check ran' "$w/out" >/dev/null && [ -s "$w/check-at" ] \
    || fail "the unrelated check did not run in the cycle: out=$(cat "$w/out") err=$(cat "$w/err")"
  first_call=$(head -1 "$w/ssh.log" | cut -d' ' -f1)
  check_at=$(cat "$w/check-at")
  spent=$((check_at - first_call))
  [ "$spent" -le 6 ] \
    || fail "four stuck hosts spent ${spent}s of one cycle against a 4s remote budget: $(cat "$w/ssh.log")"
  [ "$(ssh_calls "$w")" -lt 4 ] \
    || fail "hosts past the spent budget must fail at once without being dialed: $(cat "$w/ssh.log")"
  pass "stuck hosts share one cycle's remote budget and the cycle still runs its other checks"
}

test_remote_exit_before_the_bound_is_not_a_timeout() {
  local w rc want
  w=$(make_world remote-exit)
  # shellcheck disable=SC2016 # literal text for the fake ssh script
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FM_FAKE_SSH_LOG:?}"' \
    'exit "${FM_FAKE_SSH_RC:?}"' > "$w/fakebin/ssh"
  for want in 124 137; do
    rc=0
    on "$w" FM_REMOTE_CALL_TIMEOUT=5 FM_FAKE_SSH_RC=$want -- \
      --bounded rsm1 fm-remote-secondmate-control.sh state rsm1 > /dev/null 2> "$w/err" || rc=$?
    [ "$rc" -eq "$want" ] || fail "a remote exit $want before the bound must pass through, got $rc: $(cat "$w/err")"
    ! grep -F 'timed out' "$w/err" >/dev/null || fail "a remote exit $want was reported as a timeout: $(cat "$w/err")"
    [ ! -e "$w/home/state/remote-call-timeouts/lab-host" ] \
      || fail "a remote exit $want must not start a timeout streak"
  done
  pass "a remote command's own 124 or 137 passes through as a normal completion"
}

# run_watcher_briefly <w> <suffix>: one short real watcher run.
run_watcher_briefly() {
  local w=$1 pid i=0
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_DATA_OVERRIDE="$w/home/data" FM_POLL=1 bash "$ROOT/bin/fm-watch.sh" > "$w/out.$2" 2> "$w/err.$2" &
  pid=$!
  while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The tick must never rewrite the record bin/fm-on.sh owns: a streak that a
# bounded call ends between ticks stays ended, and the watcher keeps running.
test_tick_tolerates_a_record_cleared_concurrently() {
  local w n
  w=$(make_world race)
  for n in 1 2 3; do
    on "$w" FM_REMOTE_CALL_TIMEOUT=1 FM_REMOTE_CALL_BACKOFF=0 -- \
      --bounded rsm1 fm-remote-file.sh get data/r.md 10 > /dev/null 2>&1 || true
  done
  touch "$w/home/state/home-summary.json"
  fm_test_track_watcher_state "$w/home/state"
  run_watcher_briefly "$w" 1
  grep -F 'lab-host' "$w/out.1" >/dev/null || fail "the streak did not wake: $(cat "$w/out.1" "$w/err.1")"
  on "$w" FM_REMOTE_CALL_BACKOFF=0 FM_FAKE_SSH_REPLY=alive -- \
    --bounded rsm1 fm-remote-secondmate-control.sh state rsm1 > /dev/null 2>&1 \
    || fail "a recovered host should answer"
  run_watcher_briefly "$w" 2
  ! grep -F 'remote-call timeout check failed' "$w/err.2" >/dev/null \
    || fail "a cleared record made the watcher exit: $(cat "$w/err.2")"
  [ -z "$(ls -A "$w/home/state/remote-call-timeouts")" ] \
    || fail "the tick resurrected a cleared record or kept an ended streak's marker: $(ls -A "$w/home/state/remote-call-timeouts")"
  for n in 1 2 3; do
    on "$w" FM_REMOTE_CALL_TIMEOUT=1 FM_REMOTE_CALL_BACKOFF=0 -- \
      --bounded rsm1 fm-remote-file.sh get data/r.md 10 > /dev/null 2>&1 || true
  done
  rm -f "$w/home/state/.wake-queue"
  run_watcher_briefly "$w" 3
  grep -F 'lab-host' "$w/out.3" >/dev/null || fail "a new streak after recovery must wake again: $(cat "$w/out.3" "$w/err.3")"
  pass "the timeout tick never rewrites a record and a new streak wakes again"
}

fm_test_run test_bounded_call_times_out_as_unavailable \
  test_timed_out_host_backs_off_without_another_bound \
  test_watcher_cycle_is_not_stalled_by_a_blocked_remote \
  test_repeated_timeouts_wake_once_naming_host_and_command \
  test_stuck_hosts_share_one_cycle_budget \
  test_remote_exit_before_the_bound_is_not_a_timeout \
  test_tick_tolerates_a_record_cleared_concurrently
