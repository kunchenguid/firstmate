#!/bin/bash
# Long-lived per-account worker for remote fm-on jobs.
#
# This process is launched by the Firstmate-owned dev.firstmate.remote-job
# LaunchAgent on macOS and by a detached restart supervisor on Linux. It claims
# only complete 0700 records staged by fm-remote-job-lib.sh under the fixed
# account queue, refuses symlinks and malformed records, and executes only a
# tracked non-symlink fm-*.sh under this worker's configured FM_ROOT/bin.
#
# Each child runs under env -i with the shared filesystem-composed PATH, HOME,
# FM_HOME, FM_ROOT_OVERRIDE, and FM_REMOTE_JOB_ACTIVE=1. Commands receive their
# captured stdin and have a 360-second default timeout. Their stdout and stderr
# are independently constrained to the job library's 1048576-byte bound. A
# record is marked done only after its bounded outputs and numeric exit status
# have been committed. The library header owns the exact record fields and
# lifecycle.
#
# The shared library header owns lane selection, FIFO, and caller-cancellation
# contracts. This serving loop implements each active lane as a tracked,
# top-level --lane process that claims one job, records itself as the claim's
# supervisor, and runs it to publication. Shutdown stops every tracked lane and
# its recorded command group, leaving interrupted records for the replacement
# worker's orphan recovery.
#
# The worker is abandoned when its configured FM_ROOT stops being a genuine
# Firstmate checkout - the state a pruned no-mistakes gate worktree, a returned
# pooled worktree, or a removed test fixture root leaves behind. It can never
# validate or execute another job from a root that is gone, so both the serving
# loop and the Linux restart supervisor stop instead of polling forever
# reparented to init. FM_REMOTE_JOB_ORPHAN_GRACE_SECONDS is how long the root
# must stay missing before that counts, so an ordinary transient never stops a
# healthy worker. The supervisor additionally bounds how many times it restarts
# a failing child, whether or not the failures are immediate: it backs off
# between immediate failures up to
# FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS and gives up after
# FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS failed children in total, since a
# restart loop only burns CPU and grows its log without bound. A child that
# stays up for FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS clears the
# consecutive-failure backoff, but not that total restart guard, so a child
# that dies just past the healthy threshold cannot restart without bound
# either. fm-on's ensure path restarts a worker that gave up.
set -u

# A non-numeric override falls back to the default rather than crashing the
# arithmetic that bounds these loops.
worker_bounded_setting() { # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}
FM_REMOTE_JOB_ORPHAN_GRACE_SECONDS=$(worker_bounded_setting "${FM_REMOTE_JOB_ORPHAN_GRACE_SECONDS:-}" 5)
FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS=$(worker_bounded_setting "${FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS:-}" 20)
FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS=$(worker_bounded_setting "${FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS:-}" 5)
FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS=$(worker_bounded_setting "${FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS:-}" 10)

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

WORKER_LOCK=
WORKER_LOCK_HELD=0
WORKER_RELEASE_OWNERSHIP=1
WORKER_SUPERVISED_PID=
WORKER_PREEMPTIBLE=0
WORKER_PREEMPTED=0
WORKER_LANE_HOME=
WORKER_LANE_HOMES=()
WORKER_LANE_PIDS=()
WORKER_LANE_STARTS=()
WORKER_LANE_JOBS=()

worker_error() { printf 'remote-job-worker: %s\n' "$1" >&2; }

worker_account_home() {
  local home=${HOME:-}
  if [ -n "$home" ]; then
    fm_remote_job_canonical_existing_dir "$home" && return 0
  fi
  unset HOME
  CDPATH='' cd ~ 2>/dev/null && pwd -P
}

worker_write_heartbeat() {
  local ready tmp
  ready=$(fm_remote_job_worker_ready_path)
  tmp=$(umask 077; mktemp "$FM_REMOTE_JOB_STATE/.ready.XXXXXX") || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$ready"
}

worker_publish_pid() {
  local pid_file tmp
  pid_file=$(fm_remote_job_worker_pid_path)
  tmp=$(umask 077; mktemp "$FM_REMOTE_JOB_STATE/.pid.XXXXXX") || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$pid_file"
}

worker_publish_identity() {
  local account_home=$1 identity identity_file tmp
  identity=$(fm_remote_job_code_identity "$FM_ROOT" "$account_home") || return 1
  identity_file=$(fm_remote_job_worker_identity_path)
  tmp=$(umask 077; mktemp "$FM_REMOTE_JOB_STATE/.identity.XXXXXX") || return 1
  printf '%s\n' "$identity" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$identity_file"
}

worker_publish_lock_owner() {
  local pid start command pid_tmp start_tmp command_tmp
  pid=${BASHPID:-$$}
  start=$(fm_remote_job_process_start "$pid") || return 1
  command=$(fm_remote_job_process_command "$pid") || return 1
  pid_tmp=$(umask 077; mktemp "$WORKER_LOCK/.pid.XXXXXX") || return 1
  start_tmp=$(umask 077; mktemp "$WORKER_LOCK/.start.XXXXXX") || { rm -f -- "$pid_tmp"; return 1; }
  command_tmp=$(umask 077; mktemp "$WORKER_LOCK/.command.XXXXXX") || { rm -f -- "$pid_tmp" "$start_tmp"; return 1; }
  printf '%s\n' "$pid" > "$pid_tmp" || { rm -f -- "$pid_tmp" "$start_tmp" "$command_tmp"; return 1; }
  printf '%s\n' "$start" > "$start_tmp" || { rm -f -- "$pid_tmp" "$start_tmp" "$command_tmp"; return 1; }
  printf '%s\n' "$command" > "$command_tmp" || { rm -f -- "$pid_tmp" "$start_tmp" "$command_tmp"; return 1; }
  chmod 600 "$pid_tmp" "$start_tmp" "$command_tmp" || { rm -f -- "$pid_tmp" "$start_tmp" "$command_tmp"; return 1; }
  mv -f -- "$command_tmp" "$WORKER_LOCK/command" || { rm -f -- "$pid_tmp" "$start_tmp" "$command_tmp"; return 1; }
  mv -f -- "$start_tmp" "$WORKER_LOCK/start" || { rm -f -- "$pid_tmp" "$start_tmp" "$WORKER_LOCK/command"; return 1; }
  mv -f -- "$pid_tmp" "$WORKER_LOCK/pid" || { rm -f -- "$pid_tmp" "$WORKER_LOCK/start" "$WORKER_LOCK/command"; return 1; }
}

worker_lock_recent() {
  local mtime now
  mtime=$(fm_remote_job_path_mtime "$WORKER_LOCK" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ $((now - mtime)) -le 10 ]
}

worker_quarantined_execution_stopped() { # <account-home>
  local account_home=$1 job state kind file pid
  fm_remote_job_regular_bounded "$WORKER_LOCK/quarantine" 256 || return 1
  fm_remote_job_lock_owner_matches_process "$account_home" && return 1
  for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
    [ -d "$job" ] && [ ! -L "$job" ] || continue
    state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
    [ "$state" = running ] || continue
    for kind in process group; do
      case "$kind" in process) file="$job/.claim/supervisor" ;; group) file="$job/.claim/group" ;; esac
      [ ! -e "$file" ] && [ ! -L "$file" ] && continue
      [ ! -L "$file" ] || return 1
      pid=$(worker_read_process_id "$file") || return 1
      worker_recorded_execution_alive "$job" "$kind" "$pid" && return 1
    done
  done
}

worker_recover_quarantine() { # <account-home>
  worker_quarantined_execution_stopped "$1" || return 1
  [ ! -L "$WORKER_LOCK/quarantine" ] || return 1
  rm -f -- "$WORKER_LOCK/quarantine"
}

worker_acquire_lock() {
  local account_home=$1 attempt=0
  while [ "$attempt" -lt 150 ]; do
    if (umask 077; mkdir "$WORKER_LOCK") 2>/dev/null; then
      WORKER_LOCK_HELD=1
      worker_publish_lock_owner || return 1
      return 0
    fi
    [ -d "$WORKER_LOCK" ] && [ ! -L "$WORKER_LOCK" ] || return 1
    if [ -e "$WORKER_LOCK/quarantine" ] || [ -L "$WORKER_LOCK/quarantine" ]; then
      worker_recover_quarantine "$account_home" || return 3
      continue
    fi
    if fm_remote_job_lock_owner_matches_process "$account_home" "$WORKER_LOCK"; then return 2; fi
    if fm_remote_job_probe "$account_home" || worker_lock_recent; then
      attempt=$((attempt + 1))
      sleep 0.1
      continue
    fi
    [ ! -L "$WORKER_LOCK/pid" ] && [ ! -L "$WORKER_LOCK/start" ] && [ ! -L "$WORKER_LOCK/command" ] || return 1
    rm -f -- "$WORKER_LOCK/pid" "$WORKER_LOCK/start" "$WORKER_LOCK/command" || return 1
    rmdir "$WORKER_LOCK" || return 1
  done
  return 1
}

worker_publish_quarantine() {
  local tmp
  [ "$WORKER_LOCK_HELD" -eq 1 ] || return 1
  tmp=$(umask 077; mktemp "$WORKER_LOCK/.quarantine.XXXXXX") || return 1
  printf 'active execution could not be confirmed stopped\n' > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$WORKER_LOCK/quarantine"
}

worker_clear_quarantine() {
  [ ! -L "$WORKER_LOCK/quarantine" ] || return 1
  rm -f -- "$WORKER_LOCK/quarantine"
}

worker_cleanup() {
  local pid_file ready identity owner_pid
  [ "$WORKER_LOCK_HELD" -eq 1 ] && [ "$WORKER_RELEASE_OWNERSHIP" -eq 1 ] || return 0
  owner_pid=$(fm_remote_job_read_single_line "$WORKER_LOCK/pid" 64 2>/dev/null || true)
  if [ -z "$owner_pid" ]; then
    [ ! -L "$WORKER_LOCK/start" ] && [ ! -L "$WORKER_LOCK/command" ] &&
      rm -f -- "$WORKER_LOCK/start" "$WORKER_LOCK/command" 2>/dev/null || true
    rmdir "$WORKER_LOCK" 2>/dev/null || true
    WORKER_LOCK_HELD=0
    return 0
  fi
  [ "$owner_pid" = "${BASHPID:-$$}" ] || return 0
  pid_file=$(fm_remote_job_worker_pid_path)
  ready=$(fm_remote_job_worker_ready_path)
  identity=$(fm_remote_job_worker_identity_path)
  [ ! -L "$pid_file" ] && rm -f -- "$pid_file" 2>/dev/null || true
  [ ! -L "$ready" ] && rm -f -- "$ready" 2>/dev/null || true
  [ ! -L "$identity" ] && rm -f -- "$identity" 2>/dev/null || true
  rm -f -- "$WORKER_LOCK/pid" "$WORKER_LOCK/start" "$WORKER_LOCK/command" 2>/dev/null || true
  rmdir "$WORKER_LOCK" 2>/dev/null || true
  WORKER_LOCK_HELD=0
}

# The configured code root is gone and stayed gone across the grace window, so
# this worker has nothing left to serve. Confirming over the window keeps a
# momentary read during an ordinary checkout operation from stopping a healthy
# worker.
worker_code_root_abandoned() {
  local waited=0
  fm_remote_job_root_is_live "$FM_ROOT" && return 1
  while [ "$waited" -lt "$FM_REMOTE_JOB_ORPHAN_GRACE_SECONDS" ]; do
    sleep 1
    waited=$((waited + 1))
    fm_remote_job_root_is_live "$FM_ROOT" && return 1
  done
  return 0
}

worker_read_process_id() { # <file>
  local file=$1 pid
  fm_remote_job_regular_bounded "$file" 64 || return 1
  pid=$(tr -d '\n' < "$file")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  printf '%s\n' "$pid"
}

worker_process_or_group_alive() { # process|group <pid>
  case "$1" in
    process) kill -0 "$2" 2>/dev/null ;;
    group) kill -0 -- "-$2" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

worker_signal_process_or_group() { # process|group <signal> <pid>
  case "$1" in
    process) kill "-$2" "$3" 2>/dev/null || true ;;
    group) kill "-$2" -- "-$3" 2>/dev/null || true ;;
  esac
}

worker_supervisor_identity_status() { # <job-dir> <pid>
  local job=$1 pid=$2 recorded_start actual_start
  recorded_start=$(fm_remote_job_read_single_line "$job/.claim/supervisor_start" 256 2>/dev/null) || return 2
  actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null) || {
    worker_process_or_group_alive process "$pid" && return 2
    return 1
  }
  fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start" && return 0
  return 1
}

worker_group_identity_status() { # <job-dir> <pid>
  local job=$1 pid=$2 recorded_start actual_start file="$1/.claim/group_start"
  [ -e "$file" ] || [ -L "$file" ] || return 3
  recorded_start=$(fm_remote_job_read_single_line "$file" 256 2>/dev/null) || return 2
  actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null) || {
    kill -0 "$pid" 2>/dev/null && return 2
    worker_process_or_group_alive group "$pid" && return 4
    return 1
  }
  fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start" && return 0
  return 1
}

worker_recorded_execution_alive() { # <job-dir> process|group <pid>
  local job=$1 kind=$2 pid=$3 identity_status
  if [ "$kind" = process ]; then
    worker_supervisor_identity_status "$job" "$pid"
    identity_status=$?
    case "$identity_status" in
      0) ;;
      1) return 1 ;;
      2) worker_process_or_group_alive process "$pid"; return ;;
    esac
  else
    worker_group_identity_status "$job" "$pid"
    identity_status=$?
    case "$identity_status" in
      0|3) ;;
      1) return 1 ;;
      2|4) worker_process_or_group_alive group "$pid"; return ;;
    esac
  fi
  worker_process_or_group_alive "$kind" "$pid"
}

worker_signal_recorded_execution() { # <job-dir> process|group <signal> <pid>
  local job=$1 kind=$2 signal=$3 pid=$4 identity_status recorded_start snapshot group_snapshot
  if [ "$kind" = process ]; then
    worker_supervisor_identity_status "$job" "$pid" || return 0
  else
    recorded_start=$(fm_remote_job_read_single_line "$job/.claim/group_start" 256 2>/dev/null || true)
    if [ "$(fm_remote_job_platform)" = linux ]; then
      case "$recorded_start" in
        linux:*:*) ;;
        *)
          snapshot=$(fm_remote_job_scope_snapshot "$FM_ROOT" "$FM_REMOTE_JOB_STATE") || return 0
          group_snapshot=$(printf '%s\n' "$snapshot" | awk -F '\t' -v group="$pid" '$3 == group')
          [ -z "$group_snapshot" ] ||
            fm_remote_job_signal_scope_snapshot "$group_snapshot" "$FM_ROOT" "$FM_REMOTE_JOB_STATE" "$signal" "$pid"
          return 0
          ;;
      esac
    fi
    worker_group_identity_status "$job" "$pid"
    identity_status=$?
    case "$identity_status" in 0|3) ;; *) return 0 ;; esac
  fi
  worker_signal_process_or_group "$kind" "$signal" "$pid"
}

worker_stop_recorded_execution() { # <job-dir>
  local job=$1 kind file pid attempt still_alive recorded_start actual_start snapshot
  for kind in process group; do
    case "$kind" in process) file="$job/.claim/supervisor" ;; group) file="$job/.claim/group" ;; esac
    [ ! -e "$file" ] && [ ! -L "$file" ] && continue
    [ ! -L "$file" ] || return 1
    pid=$(worker_read_process_id "$file") || return 1
    worker_signal_recorded_execution "$job" "$kind" TERM "$pid"
    worker_signal_recorded_execution "$job" "$kind" KILL "$pid"
    wait "$pid" 2>/dev/null || true
  done
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    still_alive=0
    for kind in process group; do
      case "$kind" in process) file="$job/.claim/supervisor" ;; group) file="$job/.claim/group" ;; esac
      [ -e "$file" ] || continue
      pid=$(worker_read_process_id "$file") || return 1
      if worker_recorded_execution_alive "$job" "$kind" "$pid"; then
        still_alive=1
        worker_signal_recorded_execution "$job" "$kind" TERM "$pid"
        worker_signal_recorded_execution "$job" "$kind" KILL "$pid"
      fi
    done
    [ "$still_alive" -eq 1 ] || break
    sleep 0.01
  done
  if [ "$still_alive" -ne 0 ]; then
    file="$job/.claim/group"
    if [ -e "$file" ] && [ ! -L "$file" ]; then
      pid=$(worker_read_process_id "$file" 2>/dev/null || true)
      recorded_start=$(fm_remote_job_read_single_line "$job/.claim/group_start" 256 2>/dev/null || true)
      if [ -n "$pid" ] && [ -n "$recorded_start" ]; then
        actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || printf '%s' -)
        snapshot=$(printf '%s\t%s\t%s\t%s\t%s' \
          "$pid" "$actual_start" "$pid" "$recorded_start" "${job##*/}")
        fm_remote_job_report_unsafe_claim_survivors "$snapshot" || true
      fi
    fi
    return 1
  fi
  rm -f -- "$job/.claim/supervisor" "$job/.claim/supervisor_start" \
    "$job/.claim/group" "$job/.claim/group_start" "$job/.claim/armed"
}

# Stop every tracked lane process and its recorded command execution. The lane
# is signalled first so it cannot dispatch further work, then the job's
# recorded supervisor and group are verified stopped; a job interrupted here
# stays running-with-a-dead-owner for the replacement worker's orphan recovery,
# exactly as a crashed single-process worker's job did.
worker_lane_identity_matches() { # <pid> <start>
  local pid=$1 start=$2 actual_start
  [ -n "$start" ] || return 1
  actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null) || return 1
  fm_remote_job_start_identity_matches "$pid" "$start" "$actual_start"
}

worker_stop_active_execution() {
  local i=0 count=${#WORKER_LANE_PIDS[@]} job pid start failed=0
  while [ "$i" -lt "$count" ]; do
    pid=${WORKER_LANE_PIDS[$i]}
    start=${WORKER_LANE_STARTS[$i]}
    job=${WORKER_LANE_JOBS[$i]}
    if worker_lane_identity_matches "$pid" "$start"; then kill -TERM "$pid" 2>/dev/null || true; fi
    if worker_lane_identity_matches "$pid" "$start"; then kill -KILL "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
    if [ -d "$job" ] && [ ! -L "$job" ]; then
      worker_stop_recorded_execution "$job" || failed=1
    fi
    i=$((i + 1))
  done
  WORKER_LANE_HOMES=()
  WORKER_LANE_PIDS=()
  WORKER_LANE_STARTS=()
  WORKER_LANE_JOBS=()
  [ "$failed" -eq 0 ]
}

# Ignore, rather than restore the default disposition for, the signals this
# handler answers. A replacement stops a Linux worker by signalling its whole
# isolated group, and the supervisor in that group forwards a second stop signal
# to this same serving child, so a repeat is the normal case and not an
# exception. Restoring the default let that second signal kill the shutdown part
# way through, which left the ownership lock behind holding a half-written temp
# file that no later worker could clear, so every replacement then failed to
# report ready. A shutdown that hangs is still stopped: the caller escalates to
# KILL, which no disposition can block.
worker_shutdown() {
  trap '' HUP INT TERM
  worker_publish_quarantine || {
    worker_error "cannot guard worker ownership for shutdown"
    trap worker_shutdown HUP INT TERM
    return 0
  }
  worker_stop_active_execution || {
    worker_error "could not stop the active command tree"
    WORKER_RELEASE_OWNERSHIP=0
    exit 125
  }
  worker_clear_quarantine || {
    worker_error "could not clear guarded worker ownership after shutdown"
    WORKER_RELEASE_OWNERSHIP=0
    exit 125
  }
  exit 0
}

worker_exit_cleanup() {
  if [ "$WORKER_RELEASE_OWNERSHIP" -eq 1 ] && ! worker_stop_active_execution; then
    worker_error "could not stop the active command tree during exit"
    worker_publish_quarantine || worker_error "could not quarantine failed exit ownership"
    WORKER_RELEASE_OWNERSHIP=0
  fi
  worker_cleanup
}

worker_claim() { # <job-dir>
  local job=$1 claim pid start pid_tmp start_tmp
  claim="$job/.claim"
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 1
  (umask 077; mkdir "$claim") || return 1
  pid=${BASHPID:-$$}
  start=$(fm_remote_job_process_start "$pid") || { rmdir "$claim" 2>/dev/null || true; return 1; }
  pid_tmp=$(umask 077; mktemp "$claim/.owner.XXXXXX") || { rmdir "$claim" 2>/dev/null || true; return 1; }
  start_tmp=$(umask 077; mktemp "$claim/.owner_start.XXXXXX") || {
    rm -f -- "$pid_tmp"
    rmdir "$claim" 2>/dev/null || true
    return 1
  }
  if ! printf '%s\n' "$pid" > "$pid_tmp" || ! printf '%s\n' "$start" > "$start_tmp" \
    || ! chmod 600 "$pid_tmp" "$start_tmp" || ! mv -f -- "$start_tmp" "$claim/owner_start" \
    || ! mv -f -- "$pid_tmp" "$claim/owner"; then
    rm -f -- "$pid_tmp" "$start_tmp" "$claim/owner" "$claim/owner_start"
    rmdir "$claim" 2>/dev/null || true
    return 1
  fi
}

worker_claim_owner_alive() { # <job-dir>
  local job=$1 claim="$1/.claim" owner pid recorded_start actual_start
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  owner="$claim/owner"
  fm_remote_job_regular_bounded "$owner" 64 || return 1
  pid=$(tr -d '\n' < "$owner")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -e "$claim/owner_start" ] || [ -L "$claim/owner_start" ]; then
    recorded_start=$(fm_remote_job_read_single_line "$claim/owner_start" 256 2>/dev/null) || return 1
    actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null) || return 1
    fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start"
    return
  fi
  kill -0 "$pid" 2>/dev/null
}

worker_clear_dead_claim() { # <job-dir>
  local job=$1 claim="$1/.claim"
  [ -e "$claim" ] || [ -L "$claim" ] || return 0
  worker_claim_owner_alive "$job" && return 1
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  [ ! -e "$claim/owner" ] || [ ! -L "$claim/owner" ] || return 1
  fm_remote_job_remove_claim_records "$claim" || return 1
  rmdir "$claim"
}

# Reclaim a running job this serving loop does not own: a record left by a
# crashed worker, whether its lane process died with it or survived it. The
# recorded execution is stopped either way - a surviving foreign lane is not
# supervised by any owner and a second lane for its home must never start
# beside it - and the record publishes unknown completion, exactly as a
# crashed single-process worker's job always has.
worker_reclaim_running_job() { # <job-dir>
  local job=$1 file state
  worker_stop_recorded_execution "$job" || return 1
  state=$(fm_remote_job_read_state "$job" 2>/dev/null) || return 1
  worker_clear_dead_claim "$job" || return 1
  [ "$state" = 'done' ] && return 0
  [ "$state" = running ] || return 1
  for file in .stdout.pipe .stderr.pipe; do
    [ ! -e "$job/$file" ] && [ ! -L "$job/$file" ] || {
      [ ! -L "$job/$file" ] || return 1
      rm -f -- "$job/$file" || return 1
    }
  done
  for file in stdout stderr; do
    [ -f "$job/$file" ] && [ ! -L "$job/$file" ] || return 1
  done
  : > "$job/stdout"
  printf 'remote job worker stopped before this job completed\n' > "$job/stderr"
  worker_publish_result "$job" 125
}

worker_read_text() { # <job-dir> <field> <max>
  local job=$1 field=$2 max=$3 value extra
  fm_remote_job_regular_bounded "$job/$field" "$max" || return 1
  IFS= read -r value < "$job/$field" || return 1
  if IFS= read -r extra < <(tail -n +2 "$job/$field"); then
    : "$extra"
    return 1
  fi
  [ -n "$value" ] || return 1
  [ "$(LC_ALL=C tr -cd '\000\015' < "$job/$field" | LC_ALL=C wc -c | tr -d ' ')" -eq 0 ] || return 1
  printf '%s\n' "$value"
}

worker_publish_result() { # <job-dir> <exit>
  local job=$1 exit_status=$2 tmp account_home
  case "$exit_status" in ''|*[!0-9]*) exit_status=125 ;; esac
  [ "$exit_status" -le 255 ] || exit_status=125
  for tmp in stdout stderr; do
    fm_remote_job_regular_bounded "$job/$tmp" "$FM_REMOTE_JOB_MAX_BYTES" || return 1
  done
  tmp=$(umask 077; mktemp "$job/.exit.XXXXXX") || return 1
  printf '%s\n' "$exit_status" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$job/exit" || { rm -f -- "$tmp"; return 1; }
  fm_remote_job_write_state "$job" 'done' || return 1
  if fm_remote_job_cancelled "$job"; then
    account_home=$(worker_account_home 2>/dev/null || true)
    if [ -n "$account_home" ]; then
      fm_remote_job_reap "$account_home" "${job##*/}" 2>/dev/null || true
    fi
  fi
}

worker_run_with_timeout() { # <job-dir> <seconds> <command> [args...]
  local job=$1 timeout=$2 group_file group_start_file armed_file group_pid group_start
  local group_tmp group_start_tmp rc tmp deadline next_check attempt timed_out=0 cancelled=0
  WORKER_PREEMPTED=0
  shift 2
  group_file="$job/.claim/group"
  group_start_file="$job/.claim/group_start"
  armed_file="$job/.claim/armed"
  set -m
  (
    while [ ! -f "$armed_file" ] || [ -L "$armed_file" ]; do
      [ -d "$job/.claim" ] && [ ! -L "$job/.claim" ] || exit 125
      sleep 0.01
    done
    exec "$@"
  ) &
  group_pid=$!
  set +m
  if [ "$(fm_remote_job_platform)" = linux ]; then
    if [ "${FM_REMOTE_JOB_TEST_DISABLE_KERNEL_CLAIM_IDENTITY:-0}" = 1 ]; then
      group_start=
    else
      group_start=$(fm_remote_job_process_kernel_start "$group_pid" 2>/dev/null || true)
    fi
  else
    group_start=$(fm_remote_job_process_start "$group_pid" 2>/dev/null || true)
  fi
  [ -n "$group_start" ] || {
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    return 125
  }
  group_tmp=$(umask 077; mktemp "$job/.claim/.group.XXXXXX") || {
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    return 125
  }
  group_start_tmp=$(umask 077; mktemp "$job/.claim/.group_start.XXXXXX") || {
    rm -f -- "$group_tmp"
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    return 125
  }
  if ! printf '%s\n' "$group_pid" > "$group_tmp" \
    || ! printf '%s\n' "$group_start" > "$group_start_tmp" \
    || ! chmod 600 "$group_tmp" "$group_start_tmp" \
    || ! mv -f -- "$group_start_tmp" "$group_start_file" \
    || ! mv -f -- "$group_tmp" "$group_file"; then
    rm -f -- "$group_tmp" "$group_start_tmp" "$group_file" "$group_start_file"
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    return 125
  fi
  tmp=$(umask 077; mktemp "$job/.claim/.armed.XXXXXX") || {
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    rm -f -- "$group_file" "$group_start_file"
    return 125
  }
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$armed_file"; then
    rm -f -- "$tmp"
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    rm -f -- "$group_file" "$group_start_file"
    return 125
  fi
  deadline=$((SECONDS + timeout))
  next_check=$((SECONDS + 1))
  while worker_process_or_group_alive group "$group_pid"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      worker_signal_process_or_group group TERM "$group_pid"
      worker_signal_process_or_group group KILL "$group_pid"
      timed_out=1
      break
    fi
    if [ "$SECONDS" -ge "$next_check" ]; then
      if fm_remote_job_cancelled "$job"; then
        worker_signal_process_or_group group TERM "$group_pid"
        attempt=0
        while worker_process_or_group_alive group "$group_pid" && [ "$attempt" -lt 20 ]; do
          attempt=$((attempt + 1))
          sleep 0.05
        done
        worker_signal_process_or_group group KILL "$group_pid"
        cancelled=1
        break
      fi
      if [ "$WORKER_PREEMPTIBLE" -eq 1 ] && worker_preempting_waiter_exists "$WORKER_LANE_HOME"; then
        worker_signal_process_or_group group TERM "$group_pid"
        attempt=0
        while worker_process_or_group_alive group "$group_pid" && [ "$attempt" -lt 20 ]; do
          attempt=$((attempt + 1))
          sleep 0.05
        done
        worker_signal_process_or_group group KILL "$group_pid"
        WORKER_PREEMPTED=1
        break
      fi
      next_check=$((SECONDS + 1))
    fi
    sleep "$FM_REMOTE_JOB_POLL_SECONDS"
  done
  wait "$group_pid" 2>/dev/null
  rc=$?
  rm -f -- "$group_file" "$group_start_file" "$armed_file"
  [ "$timed_out" -eq 0 ] || return 124
  [ "$cancelled" -eq 0 ] || return 130
  [ "$WORKER_PREEMPTED" -eq 0 ] || return "$FM_REMOTE_JOB_PREEMPTED_EXIT"
  return "$rc"
}

worker_job_command() { # <job-dir>; the first argv element of a staged record
  local job=$1 first=
  fm_remote_job_regular_bounded "$job/argv" "$FM_REMOTE_JOB_MAX_BYTES" || return 1
  IFS= read -r -d '' first < "$job/argv" || [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

worker_preempting_waiter_exists() { # <lane-home>
  local lane_home=$1 job state command job_home
  for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
    [ -d "$job" ] && [ ! -L "$job" ] || continue
    state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
    [ "$state" = queued ] || continue
    fm_remote_job_cancelled "$job" && continue
    # Lanes are per home, so only a waiter for this lane's own home may
    # preempt; another home's queue drains through its own lane.
    job_home=$(worker_read_text "$job" home 8192 2>/dev/null || true)
    [ "$job_home" = "$lane_home" ] || continue
    command=$(worker_job_command "$job" 2>/dev/null || true)
    fm_remote_job_command_preemptible "$command" || return 0
  done
  return 1
}

worker_cleanup_output_capture() { # <job-dir> <stdout-reader> <stderr-reader>
  local job=$1 stdout_reader=$2 stderr_reader=$3
  kill "$stdout_reader" "$stderr_reader" 2>/dev/null || true
  wait "$stdout_reader" 2>/dev/null || true
  wait "$stderr_reader" 2>/dev/null || true
  rm -f -- "$job/.stdout.pipe" "$job/.stderr.pipe"
}

worker_capture_output() { # <fifo> <destination>
  local fifo=$1 destination=$2
  {
    head -c "$FM_REMOTE_JOB_MAX_BYTES"
    cat >/dev/null
  } < "$fifo" > "$destination"
}

worker_run_job() { # <account-home> <job-dir>
  local account_home=$1 job=$2 root home command command_path git_bin rc deadline remaining
  local stdout_pipe stderr_pipe stdout_reader stderr_reader preemptible=0
  local -a argv child_env
  root=$(worker_read_text "$job" root 8192) || { worker_publish_result "$job" 126; return; }
  home=$(worker_read_text "$job" home 8192) || { worker_publish_result "$job" 126; return; }
  root=$(fm_remote_job_canonical_existing_dir "$root") || { worker_publish_result "$job" 126; return; }
  home=$(fm_remote_job_canonical_home "$home") || { worker_publish_result "$job" 126; return; }
  # The lane key everywhere - dispatch and the preemption scan - is the staged
  # home field's exact text, so this comparison value is read the same way.
  WORKER_LANE_HOME=$(worker_read_text "$job" home 8192 2>/dev/null || true)
  [ "$root" = "$FM_ROOT" ] || { worker_publish_result "$job" 126; return; }
  [ -f "$root/AGENTS.md" ] && [ ! -L "$root/AGENTS.md" ] &&
    [ -d "$root/bin" ] && [ ! -L "$root/bin" ] || { worker_publish_result "$job" 126; return; }
  fm_remote_job_regular_bounded "$job/argv" "$FM_REMOTE_JOB_MAX_BYTES" || { worker_publish_result "$job" 126; return; }
  fm_remote_job_regular_bounded "$job/stdin" "$FM_REMOTE_JOB_MAX_BYTES" || { worker_publish_result "$job" 126; return; }
  deadline=$(fm_remote_job_read_deadline "$job") || { worker_publish_result "$job" 126; return; }
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || { worker_publish_result "$job" 124; return; }
  argv=()
  while IFS= read -r -d '' command; do argv+=("$command"); done < "$job/argv"
  [ "${#argv[@]}" -ge 1 ] || { worker_publish_result "$job" 126; return; }
  command=${argv[0]}
  case "$command" in fm-*.sh) ;; *) worker_publish_result "$job" 126; return ;; esac
  case "$command" in */*|*..*) worker_publish_result "$job" 126; return ;; esac
  if fm_remote_job_command_preemptible "$command"; then preemptible=1; fi
  command_path="$root/bin/$command"
  [ -f "$command_path" ] && [ ! -L "$command_path" ] && [ -x "$command_path" ] || {
    worker_publish_result "$job" 126
    return
  }
  fm_remote_job_compose_operator_path "$account_home" >/dev/null
  git_bin=$(fm_remote_job_operator_tool git 2>/dev/null || true)
  [ -n "$git_bin" ] || { worker_publish_result "$job" 126; return; }
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || { worker_publish_result "$job" 124; return; }
  set +e
  worker_run_with_timeout "$job" "$remaining" \
    "$git_bin" -C "$root" ls-files --error-unmatch "bin/$command" >/dev/null 2>&1
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    124) worker_publish_result "$job" 124; return ;;
    125) worker_publish_result "$job" 125; return ;;
    *) worker_publish_result "$job" 126; return ;;
  esac
  fm_remote_job_build_child_path "$root" >/dev/null
  for command in stdin stdout stderr; do
    [ -f "$job/$command" ] && [ ! -L "$job/$command" ] || { worker_publish_result "$job" 126; return; }
  done
  stdout_pipe="$job/.stdout.pipe"
  stderr_pipe="$job/.stderr.pipe"
  [ ! -e "$stdout_pipe" ] && [ ! -L "$stdout_pipe" ] && [ ! -e "$stderr_pipe" ] && [ ! -L "$stderr_pipe" ] || {
    worker_publish_result "$job" 125
    return
  }
  mkfifo "$stdout_pipe" "$stderr_pipe" || { worker_publish_result "$job" 125; return; }
  chmod 600 "$stdout_pipe" "$stderr_pipe" || {
    rm -f -- "$stdout_pipe" "$stderr_pipe"
    worker_publish_result "$job" 125
    return
  }
  worker_capture_output "$stdout_pipe" "$job/stdout" &
  stdout_reader=$!
  worker_capture_output "$stderr_pipe" "$job/stderr" &
  stderr_reader=$!
  child_env=(
    /usr/bin/env -i
    "PATH=$FM_REMOTE_JOB_CHILD_PATH"
    "HOME=$account_home"
    "FM_HOME=$home"
    "FM_ROOT_OVERRIDE=$root"
    "FM_REMOTE_JOB_STATE_ROOT=$FM_REMOTE_JOB_STATE"
    FM_REMOTE_JOB_ACTIVE=1
  )
  if [ -n "${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-}" ]; then
    child_env+=("FM_REMOTE_JOB_PLATFORM_OVERRIDE=$FM_REMOTE_JOB_PLATFORM_OVERRIDE")
  fi
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || {
    worker_cleanup_output_capture "$job" "$stdout_reader" "$stderr_reader"
    worker_publish_result "$job" 124
    return
  }
  set +e
  WORKER_PREEMPTIBLE=$preemptible
  worker_run_with_timeout "$job" "$remaining" "${child_env[@]}" \
    "$command_path" "${argv[@]:1}" < "$job/stdin" > "$stdout_pipe" 2> "$stderr_pipe"
  rc=$?
  WORKER_PREEMPTIBLE=0
  wait "$stdout_reader"
  wait "$stderr_reader"
  rm -f -- "$stdout_pipe" "$stderr_pipe"
  set -e
  if [ "$WORKER_PREEMPTED" -eq 1 ]; then
    : > "$job/stdout"
    : > "$job/stderr"
  fi
  worker_publish_result "$job" "$rc" || worker_error "could not publish result for ${job##*/}"
}

# Finalize a cancelled record nobody waits on: publish the interrupt result so
# the record is complete, then reap it because its caller is gone.
worker_finalize_cancelled() { # <account-home> <job-dir>
  local account_home=$1 job=$2
  : > "$job/stdout" 2>/dev/null || true
  printf 'remote job cancelled after its caller disconnected\n' > "$job/stderr" 2>/dev/null || true
  worker_publish_result "$job" 130 || return 1
  fm_remote_job_reap "$account_home" "${job##*/}" || true
}

worker_lane_busy() { # <home>
  local home=$1 i=0 count=${#WORKER_LANE_HOMES[@]}
  while [ "$i" -lt "$count" ]; do
    [ "${WORKER_LANE_HOMES[$i]}" != "$home" ] || return 0
    i=$((i + 1))
  done
  return 1
}

worker_lane_owns_job() { # <job-dir>
  local job=$1 i=0 count=${#WORKER_LANE_JOBS[@]}
  while [ "$i" -lt "$count" ]; do
    [ "${WORKER_LANE_JOBS[$i]}" != "$job" ] || return 0
    i=$((i + 1))
  done
  return 1
}

worker_reap_finished_lanes() {
  local i=0 count=${#WORKER_LANE_PIDS[@]} pid start
  local live_homes=() live_pids=() live_starts=() live_jobs=()
  while [ "$i" -lt "$count" ]; do
    pid=${WORKER_LANE_PIDS[$i]}
    start=${WORKER_LANE_STARTS[$i]}
    if worker_lane_identity_matches "$pid" "$start"; then
      live_homes+=("${WORKER_LANE_HOMES[$i]}")
      live_pids+=("$pid")
      live_starts+=("$start")
      live_jobs+=("${WORKER_LANE_JOBS[$i]}")
    else
      wait "$pid" 2>/dev/null || true
    fi
    i=$((i + 1))
  done
  WORKER_LANE_HOMES=()
  WORKER_LANE_PIDS=()
  WORKER_LANE_STARTS=()
  WORKER_LANE_JOBS=()
  i=0
  count=${#live_pids[@]}
  while [ "$i" -lt "$count" ]; do
    WORKER_LANE_HOMES+=("${live_homes[$i]}")
    WORKER_LANE_PIDS+=("${live_pids[$i]}")
    WORKER_LANE_STARTS+=("${live_starts[$i]}")
    WORKER_LANE_JOBS+=("${live_jobs[$i]}")
    i=$((i + 1))
  done
}

# One lane's whole execution of one job, run as a background lane process:
# claim, record this process as the claim supervisor, honor a cancel that
# arrived before running, establish the deadline, run to publication, and reap
# the record when its caller cancelled and can no longer reap it.
worker_lane_execute() { # <account-home> <job-dir>
  local account_home=$1 job=$2 timeout queue_deadline deadline
  local supervisor_pid supervisor_start pid_tmp start_tmp
  worker_claim "$job" || return 0
  supervisor_pid=${BASHPID:-$$}
  supervisor_start=$(fm_remote_job_process_start "$supervisor_pid") || {
    worker_publish_result "$job" 125 || true
    return 0
  }
  pid_tmp=$(umask 077; mktemp "$job/.claim/.supervisor.XXXXXX") || {
    worker_publish_result "$job" 125 || true
    return 0
  }
  start_tmp=$(umask 077; mktemp "$job/.claim/.supervisor_start.XXXXXX") || {
    rm -f -- "$pid_tmp"
    worker_publish_result "$job" 125 || true
    return 0
  }
  if ! printf '%s\n' "$supervisor_pid" > "$pid_tmp" \
    || ! printf '%s\n' "$supervisor_start" > "$start_tmp" \
    || ! chmod 600 "$pid_tmp" "$start_tmp" \
    || ! mv -f -- "$start_tmp" "$job/.claim/supervisor_start" \
    || ! mv -f -- "$pid_tmp" "$job/.claim/supervisor"; then
    rm -f -- "$pid_tmp" "$start_tmp" "$job/.claim/supervisor_start"
    worker_publish_result "$job" 125 || true
    return 0
  fi
  if fm_remote_job_cancelled "$job"; then
    worker_finalize_cancelled "$account_home" "$job" || true
    return 0
  fi
  queue_deadline=$(fm_remote_job_read_number "$job" queue_deadline 2>/dev/null || true)
  case "$queue_deadline" in ''|*[!0-9]*) worker_publish_result "$job" 126 || true; return 0 ;; esac
  if [ "$(date +%s)" -ge "$queue_deadline" ]; then
    worker_publish_result "$job" 124 || true
    return 0
  fi
  timeout=$(fm_remote_job_read_number "$job" timeout 2>/dev/null || true)
  case "$timeout" in ''|*[!0-9]*) worker_publish_result "$job" 126 || true; return 0 ;; esac
  if [ "$timeout" -gt 3600 ]; then
    worker_publish_result "$job" 126 || true
    return 0
  fi
  # The deadline is measured in whole seconds from a truncated clock read, so
  # the +1 keeps the granted window at least the recorded timeout instead of
  # silently shaving up to a second off it.
  deadline=$(( $(date +%s) + timeout + 1 ))
  fm_remote_job_write_number "$job" deadline "$deadline" || {
    worker_publish_result "$job" 125 || true
    return 0
  }
  fm_remote_job_write_state "$job" running || {
    worker_publish_result "$job" 125 || true
    return 0
  }
  worker_run_job "$account_home" "$job"
  if fm_remote_job_cancelled "$job"; then
    fm_remote_job_reap "$account_home" "${job##*/}" || true
  fi
}

# Each lane runs as its own top-level worker process (--lane), not a
# backgrounded subshell: a bash subshell does not reliably reap its dead
# children, and a zombie group leader keeps its process group signalable, so a
# subshell-hosted monitor loop can believe a finished command is still running
# until the job deadline. A top-level shell is the context the monitor loop
# has always run in.
worker_start_lane() { # <job-dir> <home>
  local job=$1 home=$2 lane_pid lane_start
  "$SCRIPT_DIR/fm-remote-job-worker.sh" --lane "${job##*/}" &
  lane_pid=$!
  lane_start=$(fm_remote_job_process_start "$lane_pid" 2>/dev/null || true)
  WORKER_LANE_HOMES+=("$home")
  WORKER_LANE_PIDS+=("$lane_pid")
  WORKER_LANE_STARTS+=("$lane_start")
  WORKER_LANE_JOBS+=("$job")
}

worker_lane_main() { # <job-id>
  local account_home job
  fm_remote_job_safe_id "$1" || { worker_error "invalid lane job id"; exit 2; }
  account_home=$(worker_account_home) || { worker_error "cannot resolve account home"; exit 1; }
  FM_ROOT=$(fm_remote_job_canonical_existing_dir "$FM_ROOT") || { worker_error "configured FM_ROOT is unsafe"; exit 1; }
  fm_remote_job_prepare_state "$account_home" || { worker_error "$FM_REMOTE_JOB_ERROR"; exit 1; }
  job=$(fm_remote_job_job_dir "$1" 2>/dev/null) || exit 0
  worker_lane_execute "$account_home" "$job"
}

worker_process_once() { # <account-home>
  local account_home=$1 job id state queue_deadline home seq candidates=''
  local reserved_index reserved_count home_reserved
  local reserved_homes=()
  worker_reap_finished_lanes
  for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
    [ -d "$job" ] && [ ! -L "$job" ] || continue
    id=${job##*/}
    fm_remote_job_safe_id "$id" || continue
    job=$(fm_remote_job_job_dir "$id" 2>/dev/null || true)
    [ -n "$job" ] || continue
    state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
    case "$state" in
      queued)
        worker_lane_owns_job "$job" && continue
        if ! worker_clear_dead_claim "$job"; then
          if worker_claim_owner_alive "$job"; then
            home=$(worker_read_text "$job" home 8192 2>/dev/null || true)
            [ -n "$home" ] && reserved_homes+=("$home")
          fi
          continue
        fi
        if fm_remote_job_cancelled "$job"; then
          worker_finalize_cancelled "$account_home" "$job" || true
          continue
        fi
        queue_deadline=$(fm_remote_job_read_number "$job" queue_deadline 2>/dev/null || true)
        case "$queue_deadline" in ''|*[!0-9]*) worker_publish_result "$job" 126 || true; continue ;; esac
        if [ "$(date +%s)" -ge "$queue_deadline" ]; then
          worker_publish_result "$job" 124 || true
          continue
        fi
        home=$(worker_read_text "$job" home 8192 2>/dev/null || true)
        [ -n "$home" ] || { worker_publish_result "$job" 126 || true; continue; }
        # A record staged by an older library has no seq; order it ahead of
        # sequenced work as the older job it is.
        seq=$(fm_remote_job_read_number "$job" seq 2>/dev/null || true)
        case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
        candidates="$candidates$seq"$'\t'"$id"$'\t'"$home"$'\n'
        ;;
      running)
        worker_lane_owns_job "$job" || worker_reclaim_running_job "$job" || true
        continue
        ;;
      *) continue ;;
    esac
  done
  [ -n "$candidates" ] || return 0
  while IFS=$'\t' read -r seq id home; do
    [ -n "$id" ] || continue
    worker_lane_busy "$home" && continue
    home_reserved=0
    reserved_index=0
    reserved_count=${#reserved_homes[@]}
    while [ "$reserved_index" -lt "$reserved_count" ]; do
      if [ "${reserved_homes[$reserved_index]}" = "$home" ]; then
        home_reserved=1
        break
      fi
      reserved_index=$((reserved_index + 1))
    done
    [ "$home_reserved" -eq 0 ] || continue
    job=$(fm_remote_job_job_dir "$id" 2>/dev/null || true)
    [ -n "$job" ] || continue
    [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = queued ] || continue
    worker_start_lane "$job" "$home"
  done < <(printf '%s' "$candidates" | sort -t $'\t' -k1,1n -k2,2)
}

main() {
  local account_home lock_status
  account_home=$(worker_account_home) || { worker_error "cannot resolve account home"; exit 1; }
  FM_ROOT=$(fm_remote_job_canonical_existing_dir "$FM_ROOT") || { worker_error "configured FM_ROOT is unsafe"; exit 1; }
  [ -f "$FM_ROOT/AGENTS.md" ] && [ ! -L "$FM_ROOT/AGENTS.md" ] || { worker_error "FM_ROOT is not a Firstmate checkout"; exit 1; }
  fm_remote_job_prepare_state "$account_home" || { worker_error "$FM_REMOTE_JOB_ERROR"; exit 1; }
  WORKER_LOCK=$(fm_remote_job_worker_lock_path)
  trap worker_exit_cleanup EXIT
  worker_acquire_lock "$account_home"
  lock_status=$?
  case "$lock_status" in
    0) ;;
    2) exit 0 ;;
    3) worker_error "worker ownership is quarantined after an unconfirmed shutdown"; exit 75 ;;
    *) worker_error "cannot acquire or safely reclaim worker ownership"; exit 1 ;;
  esac
  trap worker_shutdown HUP INT TERM
  worker_publish_identity "$account_home" || { worker_error "cannot publish worker code identity"; exit 1; }
  worker_publish_pid || { worker_error "cannot publish worker pid"; exit 1; }
  while :; do
    worker_write_heartbeat || { worker_error "cannot update worker heartbeat"; exit 1; }
    # Checked right after a fresh heartbeat, so the grace window cannot make a
    # still-healthy worker read as unready to a concurrent probe.
    if worker_code_root_abandoned; then
      worker_error "configured FM_ROOT $FM_ROOT no longer exists; stopping the abandoned worker"
      exit 0
    fi
    worker_reap=0
    if [ "$worker_reap" -eq 0 ]; then
      fm_remote_job_reap_stale "$account_home" || true
      worker_reap=1
    fi
    worker_process_once "$account_home"
    sleep "$FM_REMOTE_JOB_POLL_SECONDS"
  done
}

worker_supervisor_cleanup_dead_child() { # <account-home> <pid>
  local account_home=$1 pid=$2 lock recorded pid_file ready identity
  fm_remote_job_prepare_state "$account_home" || return 1
  lock=$(fm_remote_job_worker_lock_path)
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  [ ! -e "$lock/quarantine" ] && [ ! -L "$lock/quarantine" ] || return 1
  recorded=$(fm_remote_job_read_single_line "$lock/pid" 64) || return 1
  [ "$recorded" = "$pid" ] || return 1
  pid_file=$(fm_remote_job_worker_pid_path)
  ready=$(fm_remote_job_worker_ready_path)
  identity=$(fm_remote_job_worker_identity_path)
  [ ! -L "$pid_file" ] && rm -f -- "$pid_file" || return 1
  [ ! -L "$ready" ] && rm -f -- "$ready" || return 1
  [ ! -L "$identity" ] && rm -f -- "$identity" || return 1
  [ ! -L "$lock/start" ] && [ ! -L "$lock/command" ] || return 1
  rm -f -- "$lock/pid" "$lock/start" "$lock/command" || return 1
  rmdir "$lock"
}

worker_supervisor_shutdown() {
  local pid=${WORKER_SUPERVISED_PID:-}
  trap - HUP INT TERM
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  exit 0
}

worker_supervisor_cleanup() {
  local owner
  [ "$WORKER_LOCK_HELD" -eq 1 ] || return 0
  owner=$(fm_remote_job_read_single_line "$WORKER_LOCK/pid" 64 2>/dev/null || true)
  [ "$owner" = "${BASHPID:-$$}" ] || return 0
  # This lease owns the supervisor, not the serving child's readiness files.
  rm -f -- "$WORKER_LOCK/pid" "$WORKER_LOCK/start" "$WORKER_LOCK/command"
  rmdir "$WORKER_LOCK"
}

worker_supervise_linux() {
  local account_home child_status started failures=0 restarts=0 backoff lock_status worker_lock
  account_home=$(worker_account_home) || { worker_error "cannot resolve account home"; return 1; }
  FM_ROOT=$(fm_remote_job_canonical_existing_dir "$FM_ROOT") || { worker_error "configured FM_ROOT is unsafe"; return 1; }
  [ -f "$FM_ROOT/AGENTS.md" ] && [ ! -L "$FM_ROOT/AGENTS.md" ] || { worker_error "FM_ROOT is not a Firstmate checkout"; return 1; }
  fm_remote_job_prepare_state "$account_home" || { worker_error "$FM_REMOTE_JOB_ERROR"; return 1; }
  worker_lock=$(fm_remote_job_worker_lock_path)
  # The serving child releases worker.lock on exit. A separate ownership lease
  # survives its restart window, preventing concurrent ensure calls from
  # accumulating independent restart loops while serving ownership is stale.
  WORKER_LOCK="$FM_REMOTE_JOB_STATE/supervisor.lock"
  trap worker_supervisor_cleanup EXIT
  trap worker_supervisor_shutdown HUP INT TERM
  worker_acquire_lock "$account_home"
  lock_status=$?
  case "$lock_status" in
    0) ;;
    2)
      if [ -e "$worker_lock/quarantine" ] || [ -L "$worker_lock/quarantine" ]; then
        worker_error "worker ownership is quarantined after an unconfirmed shutdown"
        return 75
      fi
      return 0
      ;;
    *) worker_error "cannot acquire supervisor ownership"; return 1 ;;
  esac
  while :; do
    if worker_code_root_abandoned; then
      worker_error "configured FM_ROOT $FM_ROOT no longer exists; stopping the abandoned worker supervisor"
      return 0
    fi
    started=$SECONDS
    "$SCRIPT_DIR/fm-remote-job-worker.sh" --serve &
    WORKER_SUPERVISED_PID=$!
    wait "$WORKER_SUPERVISED_PID" 2>/dev/null
    child_status=$?
    if [ "$child_status" -eq 0 ]; then
      WORKER_SUPERVISED_PID=
      return 0
    fi
    if [ "$child_status" -eq 75 ]; then
      WORKER_SUPERVISED_PID=
      return 75
    fi
    worker_supervisor_cleanup_dead_child "$account_home" "$WORKER_SUPERVISED_PID" || true
    WORKER_SUPERVISED_PID=
    restarts=$((restarts + 1))
    if [ "$restarts" -ge "$FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS" ]; then
      worker_error "remote job worker exited $restarts times; stopping the supervisor"
      return 1
    fi
    if [ $((SECONDS - started)) -ge "$FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS" ]; then
      failures=0
      sleep 0.1
      continue
    fi
    failures=$((failures + 1))
    backoff=$failures
    [ "$backoff" -le "$FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS" ] ||
      backoff=$FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS
    sleep "$backoff"
  done
}

case "${1:-}" in
  --serve)
    [ "$#" -eq 1 ] || { worker_error "unexpected worker arguments"; exit 2; }
    main
    ;;
  --lane)
    [ "$#" -eq 2 ] || { worker_error "unexpected worker arguments"; exit 2; }
    worker_lane_main "$2"
    ;;
  '')
    if [ "$(fm_remote_job_platform)" = linux ]; then worker_supervise_linux; else main; fi
    ;;
  *) worker_error "unexpected worker arguments"; exit 2 ;;
esac
