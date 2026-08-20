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
# The worker is abandoned when its configured FM_ROOT stops being a genuine
# Firstmate checkout - the state a pruned no-mistakes gate worktree, a returned
# pooled worktree, or a removed test fixture root leaves behind. It can never
# validate or execute another job from a root that is gone, so both the serving
# loop and the Linux restart supervisor stop instead of polling forever
# reparented to init. FM_REMOTE_JOB_ORPHAN_GRACE_SECONDS is how long the root
# must stay missing before that counts, so an ordinary transient never stops a
# healthy worker. The supervisor additionally refuses to restart a child that
# keeps failing immediately: it backs off up to
# FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS and gives up after
# FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS consecutive failures, since a restart
# loop that never stays up only burns CPU and grows its log without bound. A
# child that stays up for FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS clears that
# count. fm-on's ensure path restarts a worker that gave up.
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

WORKER_ACTIVE_JOB=
WORKER_LOCK=
WORKER_LOCK_HELD=0
WORKER_RELEASE_OWNERSHIP=1
WORKER_SUPERVISED_PID=
WORKER_PREEMPTIBLE=0
WORKER_PREEMPTED=0

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
      worker_process_or_group_alive "$kind" "$pid" && return 1
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
    if fm_remote_job_lock_owner_matches_process "$account_home"; then return 2; fi
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

worker_stop_recorded_execution() { # <job-dir>
  local job=$1 kind file pid attempt still_alive
  for kind in process group; do
    case "$kind" in process) file="$job/.claim/supervisor" ;; group) file="$job/.claim/group" ;; esac
    [ ! -e "$file" ] && [ ! -L "$file" ] && continue
    [ ! -L "$file" ] || return 1
    pid=$(worker_read_process_id "$file") || return 1
    worker_signal_process_or_group "$kind" TERM "$pid"
    worker_signal_process_or_group "$kind" KILL "$pid"
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
      worker_process_or_group_alive "$kind" "$pid" && still_alive=1
    done
    [ "$still_alive" -eq 1 ] || break
    sleep 0.01
  done
  [ "$still_alive" -eq 0 ] || return 1
  rm -f -- "$job/.claim/supervisor" "$job/.claim/group" "$job/.claim/armed"
}

worker_stop_active_execution() {
  local job=${WORKER_ACTIVE_JOB:-} owner owner_pid state
  if [ -n "$job" ]; then
    worker_stop_recorded_execution "$job" || return 1
  else
    for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
      [ -d "$job" ] && [ ! -L "$job" ] || continue
      state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
      [ "$state" = running ] || continue
      owner="$job/.claim/owner"
      owner_pid=$(worker_read_process_id "$owner" 2>/dev/null || true)
      [ "$owner_pid" = "${BASHPID:-$$}" ] || continue
      worker_stop_recorded_execution "$job" || return 1
    done
  fi
  WORKER_ACTIVE_JOB=
}

worker_shutdown() {
  trap - HUP INT TERM
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
  local job=$1 claim
  claim="$job/.claim"
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 1
  (umask 077; mkdir "$claim") || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$claim/owner" || { rmdir "$claim" 2>/dev/null || true; return 1; }
  chmod 600 "$claim/owner" || { rm -f -- "$claim/owner"; rmdir "$claim" 2>/dev/null || true; return 1; }
}

worker_claim_owner_alive() { # <job-dir>
  local job=$1 claim="$1/.claim" owner pid
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  owner="$claim/owner"
  fm_remote_job_regular_bounded "$owner" 64 || return 1
  pid=$(tr -d '\n' < "$owner")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

worker_clear_dead_claim() { # <job-dir>
  local job=$1 claim="$1/.claim"
  [ -e "$claim" ] || [ -L "$claim" ] || return 0
  worker_claim_owner_alive "$job" && return 1
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  [ ! -e "$claim/owner" ] || [ ! -L "$claim/owner" ] || return 1
  rm -f -- "$claim/owner" "$claim/supervisor" "$claim/group" "$claim/armed" || return 1
  rmdir "$claim"
}

worker_recover_orphaned_job() { # <job-dir>
  local job=$1 file
  worker_claim_owner_alive "$job" && return 1
  worker_stop_recorded_execution "$job" || return 1
  worker_clear_dead_claim "$job" || return 1
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
  local job=$1 exit_status=$2 tmp
  case "$exit_status" in ''|*[!0-9]*) exit_status=125 ;; esac
  [ "$exit_status" -le 255 ] || exit_status=125
  for tmp in stdout stderr; do
    fm_remote_job_regular_bounded "$job/$tmp" "$FM_REMOTE_JOB_MAX_BYTES" || return 1
  done
  tmp=$(umask 077; mktemp "$job/.exit.XXXXXX") || return 1
  printf '%s\n' "$exit_status" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$job/exit" || { rm -f -- "$tmp"; return 1; }
  fm_remote_job_write_state "$job" 'done'
}

worker_run_with_timeout() { # <job-dir> <seconds> <command> [args...]
  local job=$1 timeout=$2 group_file armed_file group_pid rc tmp deadline next_heartbeat attempt
  local timed_out=0 heartbeat_failed=0
  WORKER_PREEMPTED=0
  shift 2
  group_file="$job/.claim/group"
  armed_file="$job/.claim/armed"
  WORKER_ACTIVE_JOB=$job
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
  tmp=$(umask 077; mktemp "$job/.claim/.group.XXXXXX") || {
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    WORKER_ACTIVE_JOB=
    return 125
  }
  printf '%s\n' "$group_pid" > "$tmp" || {
    rm -f -- "$tmp"
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    WORKER_ACTIVE_JOB=
    return 125
  }
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$group_file"; then
    rm -f -- "$tmp"
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    WORKER_ACTIVE_JOB=
    return 125
  fi
  tmp=$(umask 077; mktemp "$job/.claim/.armed.XXXXXX") || {
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    rm -f -- "$group_file"
    WORKER_ACTIVE_JOB=
    return 125
  }
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$armed_file"; then
    rm -f -- "$tmp"
    worker_signal_process_or_group group KILL "$group_pid"
    wait "$group_pid" 2>/dev/null || true
    rm -f -- "$group_file"
    WORKER_ACTIVE_JOB=
    return 125
  fi
  deadline=$((SECONDS + timeout))
  next_heartbeat=$((SECONDS + 1))
  while worker_process_or_group_alive group "$group_pid"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      worker_signal_process_or_group group TERM "$group_pid"
      worker_signal_process_or_group group KILL "$group_pid"
      timed_out=1
      break
    fi
    if [ "$SECONDS" -ge "$next_heartbeat" ]; then
      if ! worker_write_heartbeat; then
        worker_signal_process_or_group group TERM "$group_pid"
        worker_signal_process_or_group group KILL "$group_pid"
        heartbeat_failed=1
        break
      fi
      if [ "$WORKER_PREEMPTIBLE" -eq 1 ] && worker_preempting_waiter_exists; then
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
      next_heartbeat=$((SECONDS + 1))
    fi
    sleep "$FM_REMOTE_JOB_POLL_SECONDS"
  done
  wait "$group_pid" 2>/dev/null
  rc=$?
  rm -f -- "$group_file" "$armed_file"
  WORKER_ACTIVE_JOB=
  [ "$timed_out" -eq 0 ] || return 124
  [ "$heartbeat_failed" -eq 0 ] || return 125
  [ "$WORKER_PREEMPTED" -eq 0 ] || return "$FM_REMOTE_JOB_PREEMPTED_EXIT"
  return "$rc"
}

worker_job_command() { # <job-dir>; the first argv element of a staged record
  local job=$1 first=
  fm_remote_job_regular_bounded "$job/argv" "$FM_REMOTE_JOB_MAX_BYTES" || return 1
  IFS= read -r -d '' first < "$job/argv" || [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

worker_preempting_waiter_exists() {
  local job state command
  for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
    [ -d "$job" ] && [ ! -L "$job" ] || continue
    state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
    [ "$state" = queued ] || continue
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

worker_process_once() { # <account-home>
  local account_home=$1 job id state queue_deadline timeout deadline
  for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
    [ -d "$job" ] && [ ! -L "$job" ] || continue
    id=${job##*/}
    fm_remote_job_safe_id "$id" || continue
    job=$(fm_remote_job_job_dir "$id" 2>/dev/null || true)
    [ -n "$job" ] || continue
    state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
    case "$state" in
      queued)
        worker_clear_dead_claim "$job" || continue
        queue_deadline=$(fm_remote_job_read_number "$job" queue_deadline 2>/dev/null || true)
        case "$queue_deadline" in ''|*[!0-9]*) worker_publish_result "$job" 126 || true; continue ;; esac
        if [ "$(date +%s)" -ge "$queue_deadline" ]; then
          worker_publish_result "$job" 124 || true
          continue
        fi
        ;;
      running)
        worker_recover_orphaned_job "$job" || true
        continue
        ;;
      *) continue ;;
    esac
    worker_claim "$job" || continue
    timeout=$(fm_remote_job_read_number "$job" timeout 2>/dev/null || true)
    case "$timeout" in ''|*[!0-9]*) worker_publish_result "$job" 126 || true; continue ;; esac
    if [ "$timeout" -gt 3600 ]; then
      worker_publish_result "$job" 126 || true
      continue
    fi
    deadline=$(( $(date +%s) + timeout ))
    fm_remote_job_write_number "$job" deadline "$deadline" || {
      worker_publish_result "$job" 125 || true
      continue
    }
    fm_remote_job_write_state "$job" running || {
      worker_publish_result "$job" 125 || true
      continue
    }
    worker_run_job "$account_home" "$job"
  done
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

worker_supervise_linux() {
  local account_home child_status started failures=0 backoff
  account_home=$(worker_account_home) || { worker_error "cannot resolve account home"; return 1; }
  FM_ROOT=$(fm_remote_job_canonical_existing_dir "$FM_ROOT") || { worker_error "configured FM_ROOT is unsafe"; return 1; }
  [ -f "$FM_ROOT/AGENTS.md" ] && [ ! -L "$FM_ROOT/AGENTS.md" ] || { worker_error "FM_ROOT is not a Firstmate checkout"; return 1; }
  fm_remote_job_prepare_state "$account_home" || { worker_error "$FM_REMOTE_JOB_ERROR"; return 1; }
  trap worker_supervisor_shutdown HUP INT TERM
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
    if [ $((SECONDS - started)) -ge "$FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS" ]; then
      failures=0
      sleep 0.1
      continue
    fi
    failures=$((failures + 1))
    if [ "$failures" -ge "$FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS" ]; then
      worker_error "remote job worker failed $failures times without staying up; stopping the supervisor"
      return 1
    fi
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
  '')
    if [ "$(fm_remote_job_platform)" = linux ]; then worker_supervise_linux; else main; fi
    ;;
  *) worker_error "unexpected worker arguments"; exit 2 ;;
esac
