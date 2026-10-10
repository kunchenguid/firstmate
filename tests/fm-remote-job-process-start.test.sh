#!/usr/bin/env bash
# Behavior tests for the remote job runner's process start identity.
#
# The storm this pins: on WSL2 `ps -o lstart` re-renders for one live process
# while /proc starttime stays fixed, so the lock's recorded start stopped
# matching, ensure treated a healthy worker as dead, and every remote command
# nohup-started another supervisor. fm_remote_job_process_start now reads the
# clock-stable /proc starttime when it exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-process-start)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FIXTURE_ROOT="$TMP_ROOT/remote-root"
ACCOUNT_HOME="$TMP_ROOT/account"
mkdir -p "$FIXTURE_ROOT/bin" "$ACCOUNT_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$FIXTURE_ROOT/bin/"
printf 'fixture\n' > "$FIXTURE_ROOT/AGENTS.md"
WORKER="$FIXTURE_ROOT/bin/fm-remote-job-worker.sh"

# The disposable state root keeps every case away from a production
# ~/.firstmate/remote-job.
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
STATE_ROOT=$FM_REMOTE_JOB_STATE_ROOT
LOCK="$STATE_ROOT/worker.lock"

# Only processes whose command names this fixture's own worker are ever touched.
fixture_pids() { # <supervisors|all>
  ps -eo pid=,command= 2>/dev/null | awk -v worker="$WORKER" -v mode="$1" '
    index($0, worker) {
      cmd = $0; sub(/^[ \t]*[0-9]+[ \t]+/, "", cmd)
      if (mode == "all" || substr(cmd, length(cmd) - length(worker) + 1) == worker) print $1
    }'
}

supervisor_count() { fixture_pids supervisors | wc -l | tr -d '[:space:]'; }

cleanup() {
  local pid
  for pid in $(fixture_pids all); do kill -KILL "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup EXIT

wait_gone() { # <pid>
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
  ! kill -0 "$1" 2>/dev/null
}

has_proc() { [ -r "/proc/$$/stat" ]; }

write_fake_proc_stat() { # <proc-root> <pid> <comm> <starttime>
  mkdir -p "$1/$2"
  printf '%s (%s) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 %s 20 21 22\n' "$2" "$3" "$4" > "$1/$2/stat"
}

test_fake_proc_token_is_stable_and_parses_comm() {
  local proc_root="$TMP_ROOT/proc-comm" first second
  write_fake_proc_stat "$proc_root" 4242 'watcher ) with (spaces' 987654
  first=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start 4242) \
    || fail "could not read a fake /proc starttime"
  [ "$first" = proc-starttime=987654 ] || fail "comm with spaces and parens shifted the field: '$first'"
  second=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start 4242) \
    || fail "could not re-read the fake /proc starttime"
  [ "$second" = "$first" ] || fail "the token changed without a starttime change"
  case "$first" in *$'\n'*) fail "token is not a single line" ;; esac
  pass "fake /proc starttime is a stable single-line token parsed after the last )"
}

test_token_changes_with_starttime() {
  local proc_root="$TMP_ROOT/proc-reuse" first second
  write_fake_proc_stat "$proc_root" 4343 worker 1000
  first=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start 4343) || fail "first read failed"
  write_fake_proc_stat "$proc_root" 4343 worker 1001
  second=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start 4343) || fail "second read failed"
  [ "$first" != "$second" ] || fail "a reused pid with a new starttime kept the same token"
  pass "token changes when the starttime changes (pid reuse)"
}

test_malformed_proc_stat_and_pid_are_rejected() {
  local proc_root="$TMP_ROOT/proc-bad"
  write_fake_proc_stat "$proc_root" 4444 worker notanumber
  FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start 4444 >/dev/null 2>&1 \
    && fail "a non-numeric starttime was accepted"
  mkdir -p "$proc_root/4445"
  printf '4445 (worker) S 1 2\n' > "$proc_root/4445/stat"
  FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start 4445 >/dev/null 2>&1 \
    && fail "a truncated stat line was accepted"
  fm_remote_job_process_start '12;x' >/dev/null 2>&1 && fail "a non-numeric pid was accepted"
  fm_remote_job_process_start '' >/dev/null 2>&1 && fail "an empty pid was accepted"
  pass "malformed /proc stat data and pids are rejected"
}

test_lstart_fallback_without_proc() {
  local live token expected
  sleep 30 &
  live=$!
  token=$(FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" fm_remote_job_process_start "$live") \
    || { kill "$live" 2>/dev/null || true; fail "fallback read failed"; }
  expected=$(LC_ALL=C ps -p "$live" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$token" in proc-starttime=*) fail "fallback returned a proc token without /proc: '$token'" ;; esac
  [ "$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" = "$expected" ] \
    || fail "fallback '$token' is not ps lstart '$expected'"
  pass "ps lstart is the fallback when /proc is absent"
}

# Wait for a fresh worker.ready heartbeat that the current code identity owns.
ensure_worker() {
  fm_remote_job_ensure_worker "$FIXTURE_ROOT" "$ACCOUNT_HOME" || fail "ensure failed: ${FM_REMOTE_JOB_ERROR:-no diagnostic}"
}

stop_fixture_worker() {
  local pid
  for pid in $(fixture_pids all); do kill -KILL "$pid" 2>/dev/null || true; done
  for pid in $(fixture_pids all); do wait_gone "$pid" || fail "fixture worker $pid would not stop"; done
  rm -rf -- "$STATE_ROOT"
}

test_dead_owner_with_stale_ready_gets_one_replacement() {
  local old pid
  stop_fixture_worker
  ensure_worker
  old=$(cat "$LOCK/pid")
  for pid in $(fixture_pids all); do kill -KILL "$pid" 2>/dev/null || true; done
  for pid in $(fixture_pids all); do wait_gone "$pid" || fail "fixture worker $pid would not stop"; done
  [ -d "$LOCK" ] || fail "an unclean exit did not retain the worker lock"
  touch -t 200001010000 "$STATE_ROOT/worker.ready" "$LOCK"
  ensure_worker
  [ "$(supervisor_count)" = 1 ] || fail "dead-owner recovery left $(supervisor_count) supervisors"
  [ "$(cat "$LOCK/pid")" != "$old" ] || fail "no replacement took the lock"
  kill -0 "$(cat "$LOCK/pid")" 2>/dev/null || fail "the replacement owner is not alive"
  pass "a dead owner with a stale heartbeat yields exactly one replacement"
}

test_repeated_ensure_never_piles_supervisors() {
  local pid i
  has_proc || { pass "repeated-ensure supervisor count skipped without /proc"; return; }
  stop_fixture_worker
  ensure_worker
  pid=$(cat "$LOCK/pid")
  case "$(cat "$LOCK/start")" in proc-starttime=*) ;; *) fail "worker did not record a /proc token" ;; esac
  i=0
  while [ "$i" -lt 5 ]; do
    i=$((i + 1))
    ensure_worker
    [ "$(supervisor_count)" = 1 ] || fail "ensure call $i left $(supervisor_count) supervisors"
  done
  [ "$(cat "$LOCK/pid")" = "$pid" ] || fail "repeated ensure replaced a healthy worker"
  pass "repeated ensure against a healthy worker keeps exactly one supervisor"
}

test_fake_proc_token_is_stable_and_parses_comm
test_token_changes_with_starttime
test_malformed_proc_stat_and_pid_are_rejected
test_lstart_fallback_without_proc
test_dead_owner_with_stale_ready_gets_one_replacement
test_repeated_ensure_never_piles_supervisors

echo "ALL TESTS PASSED"
