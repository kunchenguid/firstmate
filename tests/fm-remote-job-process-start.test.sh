#!/usr/bin/env bash
# Process-start identity for the remote job runner.
# On a Linux-compatible /proc, fm_remote_job_process_start uses starttime ticks
# so a changing ps lstart for the same live pid cannot break the owner match.
# Elsewhere it keeps ps -o lstart=.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-job-process-start)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$ACCOUNT_HOME"
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

write_fake_proc_stat() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" \
    > "$proc_root/$pid/stat"
}

write_lock_owner() {
  local lock pid start command
  fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail "could not prepare remote job state"
  lock=$(fm_remote_job_worker_lock_path)
  mkdir -p "$lock"
  pid=$1
  start=$2
  command=$3
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$start" > "$lock/start"
  printf '%s\n' "$command" > "$lock/command"
}

test_fake_proc_starttime_ignores_ps_lstart_and_parses_comm_safely() {
  local proc_root pid first second
  proc_root="$TMP_ROOT/proc-comm"
  pid=4242
  write_fake_proc_stat "$proc_root" "$pid" 987654
  first=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start "$pid") \
    || fail "could not read fake /proc starttime"
  [ "$first" = 987654 ] || fail "starttime with spaces/parens in comm was '$first', want 987654"
  write_fake_proc_stat "$proc_root" "$pid" 987654
  second=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start "$pid") \
    || fail "could not re-read fake /proc starttime"
  [ "$second" = "$first" ] || fail "fake /proc starttime changed without a tick change"
  write_fake_proc_stat "$proc_root" "$pid" 987655
  second=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start "$pid") \
    || fail "could not read reused fake /proc pid"
  [ "$second" = 987655 ] || fail "changed starttime was not detected (got '$second')"
  pass "fake /proc starttime parses after the last ) and ignores a would-be ps lstart"
}

test_linux_live_pid_owner_match_survives_changed_ps_lstart() {
  local live first second lstart command
  case "$(uname -s)" in
    Linux) ;;
    *)
      pass "live Linux owner-match regression skipped on $(uname -s)"
      return
      ;;
  esac
  sleep 30 &
  live=$!
  first=$(fm_remote_job_process_start "$live") \
    || { kill "$live" 2>/dev/null || true; fail "could not read live process start identity"; }
  case "$first" in
    ''|*[!0-9]*)
      kill "$live" 2>/dev/null || true
      fail "Linux start identity was not starttime ticks ('$first')"
      ;;
  esac
  lstart=$( { [ -x /bin/ps ] && /bin/ps -p "$live" -o lstart= || /usr/bin/ps -p "$live" -o lstart=; } 2>/dev/null || true)
  [ -n "$lstart" ] || { kill "$live" 2>/dev/null || true; fail "could not read ps lstart for the live pid"; }
  [ "$first" != "$lstart" ] \
    || { kill "$live" 2>/dev/null || true; fail "Linux start identity still equals ps lstart ('$first')"; }
  second=$(fm_remote_job_process_start "$live") \
    || { kill "$live" 2>/dev/null || true; fail "could not re-read live process start identity"; }
  [ "$second" = "$first" ] \
    || { kill "$live" 2>/dev/null || true; fail "live start identity drifted ('$first' then '$second')"; }
  command=$(fm_remote_job_process_command "$live") \
    || { kill "$live" 2>/dev/null || true; fail "could not read live process command"; }
  write_lock_owner "$live" "$first" "$command"
  fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME" \
    || { kill "$live" 2>/dev/null || true; fail "owner match failed for a live pid whose ps lstart differs from starttime"; }
  write_lock_owner "$live" "invalid identity" "$command"
  if fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME"; then
    kill "$live" 2>/dev/null || true
    fail "a mismatching legacy identity was accepted"
  fi
  write_lock_owner "$live" "$((first + 1))" "$command"
  if fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME"; then
    kill "$live" 2>/dev/null || true
    fail "a mismatching tick identity was accepted"
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "changed ps lstart for the same live pid no longer breaks the Linux owner match"
}

test_lstart_fallback_mismatch() (
  local live lstart command status
  export FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc"
  sleep 30 &
  live=$!
  trap 'kill "$live" 2>/dev/null || true; wait "$live" 2>/dev/null || true' EXIT
  lstart=$(fm_remote_job_process_start "$live") || fail "fallback identity read failed"
  case "$lstart" in *[!0-9]*) ;; *) fail "fallback did not return lstart" ;; esac
  command=$(fm_remote_job_process_command "$live") || fail "fallback command read failed"
  write_lock_owner "$live" "$lstart" "$command"
  fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME" || fail "fallback owner did not match"
  write_lock_owner "$live" "Mon Jan  1 00:00:00 2001" "$command"
  status=0
  fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME" || status=$?
  [ "$status" -eq 1 ] || fail "fallback mismatch did not return ordinary failure"
  pass "lstart fallback preserves ordinary mismatch recovery"
)

test_legacy_worker_upgrade() (
  local drift=${1:-0} fixture="$TMP_ROOT/upgrade-${1:-0}" old_pid new_pid lock start
  [ "$(uname -s)" = Linux ] || return 0
  mkdir -p "$fixture/bin" "$fixture/account"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$fixture/bin/"
  printf 'fixture\n' > "$fixture/AGENTS.md"
  cat >> "$fixture/bin/fm-remote-job-lib.sh" <<'LEGACY'
fm_remote_job_process_start() {
  local ps_bin
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; else ps_bin=/usr/bin/ps; fi
  "$ps_bin" -p "$1" -o lstart=
}
LEGACY
  export FM_REMOTE_JOB_STATE_ROOT="$fixture/state"
  export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
  # shellcheck disable=SC2329 # trap EXIT invokes this cleanup indirectly.
  upgrade_cleanup() {
    local child
    for child in $(jobs -pr); do
      kill -TERM -- "-$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
    done
  }
  trap upgrade_cleanup EXIT
  fm_remote_job_ensure_worker "$fixture" "$fixture/account" || fail "legacy worker did not become ready"
  lock=$(fm_remote_job_worker_lock_path)
  old_pid=$(cat "$lock/pid")
  start=$(cat "$lock/start")
  case "$start" in *[!0-9]*) ;; *) fail "fixture did not record legacy lstart" ;; esac
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$fixture/bin/fm-remote-job-lib.sh"
  if [ "$drift" -eq 1 ]; then
    start=$(date -d "$start 27 seconds ago" '+%a %b %e %T %Y') || fail "could not simulate legacy drift"
    printf '%s\n' "$start" > "$lock/start"
  fi
  fm_remote_job_ensure_worker "$fixture" "$fixture/account" || fail "upgraded worker did not become ready"
  new_pid=$(cat "$lock/pid")
  [ "$new_pid" != "$old_pid" ] || fail "legacy worker was not replaced"
  ! kill -0 "$old_pid" 2>/dev/null || fail "legacy worker survived replacement"
  start=$(cat "$lock/start")
  case "$start" in ''|*[!0-9]*) fail "replacement did not record ticks" ;; esac
  fm_remote_job_ensure_worker "$fixture" "$fixture/account" || fail "repeated ensure failed"
  [ "$(cat "$lock/pid")" = "$new_pid" ] || fail "repeated ensure replaced the current worker"
  pass "live legacy worker upgrades to a single reusable tick-identity worker"
)

test_fake_proc_starttime_ignores_ps_lstart_and_parses_comm_safely
test_lstart_fallback_mismatch || exit 1
test_legacy_worker_upgrade || exit 1
test_legacy_worker_upgrade 1 || exit 1
test_linux_live_pid_owner_match_survives_changed_ps_lstart

echo "ALL TESTS PASSED"
