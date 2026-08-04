#!/bin/bash
# Long-lived per-account worker for remote fm-on jobs.
#
# This process is launched by the Firstmate-owned dev.firstmate.remote-job
# LaunchAgent on macOS and by the matching Linux bootstrap path. It claims only
# complete 0700 records staged by fm-remote-job-lib.sh under the fixed account
# queue, refuses symlinks and malformed records, and executes only a tracked
# non-symlink fm-*.sh under this worker's configured FM_ROOT/bin.
#
# Each child runs under env -i with the shared filesystem-composed PATH, HOME,
# FM_HOME, FM_ROOT_OVERRIDE, and FM_REMOTE_JOB_ACTIVE=1. Commands receive their
# captured stdin and have a 300-second default timeout. Their stdout and stderr
# are independently constrained to the job library's 1048576-byte bound. A
# record is marked done only after its bounded outputs and numeric exit status
# have been committed. The library header owns the exact record fields and
# lifecycle.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

WORKER_ACTIVE_JOB=
WORKER_ACTIVE_SUPERVISOR_PID=

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

worker_cleanup() {
  local pid_file ready
  pid_file=$(fm_remote_job_worker_pid_path)
  ready=$(fm_remote_job_worker_ready_path)
  [ ! -L "$pid_file" ] && rm -f -- "$pid_file" 2>/dev/null || true
  [ ! -L "$ready" ] && rm -f -- "$ready" 2>/dev/null || true
  rmdir "$FM_REMOTE_JOB_STATE/worker.lock" 2>/dev/null || true
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
  if [ "$still_alive" -eq 1 ]; then
    for kind in process group; do
      case "$kind" in process) file="$job/.claim/supervisor" ;; group) file="$job/.claim/group" ;; esac
      [ -e "$file" ] || continue
      pid=$(worker_read_process_id "$file") || return 1
      worker_signal_process_or_group "$kind" KILL "$pid"
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
  fi
  [ "$still_alive" -eq 0 ] || return 1
  rm -f -- "$job/.claim/supervisor" "$job/.claim/group" "$job/.claim/armed"
}

worker_stop_active_execution() {
  local supervisor=${WORKER_ACTIVE_SUPERVISOR_PID:-} job=${WORKER_ACTIVE_JOB:-}
  if [ -n "$supervisor" ]; then
    kill -TERM "$supervisor" 2>/dev/null || true
    wait "$supervisor" 2>/dev/null || true
  fi
  [ -n "$job" ] || return 0
  worker_stop_recorded_execution "$job" || return 1
  WORKER_ACTIVE_SUPERVISOR_PID=
  WORKER_ACTIVE_JOB=
}

worker_shutdown() {
  trap - HUP INT TERM
  worker_stop_active_execution || {
    worker_error "could not stop the active command tree"
    exit 125
  }
  worker_cleanup
  exit 0
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
  local job=$1 timeout=$2 supervisor_file armed_file rc tmp
  shift 2
  supervisor_file="$job/.claim/supervisor"
  armed_file="$job/.claim/armed"
  WORKER_ACTIVE_JOB=$job
  perl -e '
    use strict;
    use warnings;
    use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
    my $seconds = shift @ARGV;
    my $group_file = shift @ARGV;
    my $armed_file = shift @ARGV;
    $seconds =~ /\A\d+\z/ or exit 125;
    pipe(my $gate_read, my $gate_write) or exit 125;
    my $pid = 0;
    my $reason = 0;
    my $signal = sub {
      my ($exit_status) = @_;
      $reason = $exit_status;
      if ($pid > 1) {
        kill q(TERM), -$pid;
        kill q(KILL), -$pid;
      }
    };
    local $SIG{ALRM} = sub { $signal->(124) };
    local $SIG{HUP} = sub { $signal->(125) };
    local $SIG{INT} = sub { $signal->(125) };
    local $SIG{TERM} = sub { $signal->(125) };
    $pid = fork();
    defined $pid or exit 125;
    if ($pid == 0) {
      close $gate_write;
      setpgrp(0, 0) or exit 125;
      my $released = q{};
      sysread($gate_read, $released, 1) == 1 or exit 125;
      close $gate_read;
      exec @ARGV;
      exit 127;
    }
    close $gate_read;
    sysopen(my $group, $group_file, O_WRONLY | O_CREAT | O_EXCL, 0600) or do {
      kill q(KILL), -$pid;
      waitpid($pid, 0);
      exit 125;
    };
    print {$group} "$pid\n" or exit 125;
    close $group or exit 125;
    my $armed = 0;
    for (1 .. 1000) {
      last if $reason;
      my @metadata = lstat $armed_file;
      if (@metadata && -f _ && !-l _) {
        $armed = 1;
        last;
      }
      select undef, undef, undef, 0.01;
    }
    if (!$armed) {
      kill q(KILL), -$pid;
      waitpid($pid, 0);
      unlink $group_file;
      exit($reason || 125);
    }
    syswrite($gate_write, q{x}, 1) == 1 or exit 125;
    close $gate_write;
    alarm $seconds;
    my $waited;
    while (1) {
      $waited = waitpid($pid, 0);
      last if $waited >= 0;
      next if $!{EINTR};
      last;
    }
    alarm 0;
    if ($reason) {
      kill q(KILL), -$pid;
      waitpid($pid, 0);
    }
    unlink $group_file;
    unlink $armed_file;
    exit $reason if $reason;
    exit 125 if $waited < 0;
    exit 128 + ($? & 127) if ($? & 127);
    exit($? >> 8);
  ' "$timeout" "$job/.claim/group" "$armed_file" "$@" &
  WORKER_ACTIVE_SUPERVISOR_PID=$!
  tmp=$(umask 077; mktemp "$job/.claim/.supervisor.XXXXXX") || {
    kill -TERM "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    wait "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    WORKER_ACTIVE_SUPERVISOR_PID=
    WORKER_ACTIVE_JOB=
    return 125
  }
  printf '%s\n' "$WORKER_ACTIVE_SUPERVISOR_PID" > "$tmp" || {
    rm -f -- "$tmp"
    kill -TERM "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    wait "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    WORKER_ACTIVE_SUPERVISOR_PID=
    WORKER_ACTIVE_JOB=
    return 125
  }
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$supervisor_file"; then
    rm -f -- "$tmp"
    kill -TERM "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    wait "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    WORKER_ACTIVE_SUPERVISOR_PID=
    WORKER_ACTIVE_JOB=
    return 125
  fi
  tmp=$(umask 077; mktemp "$job/.claim/.armed.XXXXXX") || {
    kill -TERM "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    wait "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    rm -f -- "$supervisor_file"
    WORKER_ACTIVE_SUPERVISOR_PID=
    WORKER_ACTIVE_JOB=
    return 125
  }
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$armed_file"; then
    rm -f -- "$tmp"
    kill -TERM "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    wait "$WORKER_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
    rm -f -- "$supervisor_file"
    WORKER_ACTIVE_SUPERVISOR_PID=
    WORKER_ACTIVE_JOB=
    return 125
  fi
  wait "$WORKER_ACTIVE_SUPERVISOR_PID"
  rc=$?
  rm -f -- "$supervisor_file" "$armed_file"
  WORKER_ACTIVE_SUPERVISOR_PID=
  WORKER_ACTIVE_JOB=
  return "$rc"
}

worker_run_job() { # <account-home> <job-dir>
  local account_home=$1 job=$2 root home command command_path git_bin rc deadline remaining
  local stdout_pipe stderr_pipe stdout_reader stderr_reader
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
  command_path="$root/bin/$command"
  [ -f "$command_path" ] && [ ! -L "$command_path" ] && [ -x "$command_path" ] || {
    worker_publish_result "$job" 126
    return
  }
  fm_remote_job_compose_operator_path "$account_home" >/dev/null
  git_bin=$(fm_remote_job_operator_tool git 2>/dev/null || true)
  [ -n "$git_bin" ] || { worker_publish_result "$job" 126; return; }
  "$git_bin" -C "$root" ls-files --error-unmatch "bin/$command" >/dev/null 2>&1 || {
    worker_publish_result "$job" 126
    return
  }
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
  head -c "$FM_REMOTE_JOB_MAX_BYTES" < "$stdout_pipe" > "$job/stdout" &
  stdout_reader=$!
  head -c "$FM_REMOTE_JOB_MAX_BYTES" < "$stderr_pipe" > "$job/stderr" &
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
  [ "$remaining" -gt 0 ] || { worker_publish_result "$job" 124; return; }
  set +e
  worker_run_with_timeout "$job" "$remaining" "${child_env[@]}" \
    "$command_path" "${argv[@]:1}" < "$job/stdin" > "$stdout_pipe" 2> "$stderr_pipe"
  rc=$?
  wait "$stdout_reader"
  wait "$stderr_reader"
  rm -f -- "$stdout_pipe" "$stderr_pipe"
  set -e
  worker_publish_result "$job" "$rc" || worker_error "could not publish result for ${job##*/}"
}

worker_process_once() { # <account-home>
  local account_home=$1 job id state deadline
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
        deadline=$(fm_remote_job_read_deadline "$job" 2>/dev/null || true)
        case "$deadline" in ''|*[!0-9]*) worker_publish_result "$job" 126 || true; continue ;; esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
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
    fm_remote_job_write_state "$job" running || {
      worker_publish_result "$job" 125 || true
      continue
    }
    worker_run_job "$account_home" "$job"
  done
}

main() {
  local account_home lock
  account_home=$(worker_account_home) || { worker_error "cannot resolve account home"; exit 1; }
  FM_ROOT=$(fm_remote_job_canonical_existing_dir "$FM_ROOT") || { worker_error "configured FM_ROOT is unsafe"; exit 1; }
  [ -f "$FM_ROOT/AGENTS.md" ] && [ ! -L "$FM_ROOT/AGENTS.md" ] || { worker_error "FM_ROOT is not a Firstmate checkout"; exit 1; }
  fm_remote_job_prepare_state "$account_home" || { worker_error "$FM_REMOTE_JOB_ERROR"; exit 1; }
  lock="$FM_REMOTE_JOB_STATE/worker.lock"
  if ! (umask 077; mkdir "$lock") 2>/dev/null; then
    exit 0
  fi
  trap worker_cleanup EXIT
  trap worker_shutdown HUP INT TERM
  worker_publish_pid || { worker_error "cannot publish worker pid"; exit 1; }
  while :; do
    worker_write_heartbeat || { worker_error "cannot update worker heartbeat"; exit 1; }
    worker_reap=0
    if [ "$worker_reap" -eq 0 ]; then
      fm_remote_job_reap_stale "$account_home" || true
      worker_reap=1
    fi
    worker_process_once "$account_home"
    sleep "$FM_REMOTE_JOB_POLL_SECONDS"
  done
}

main "$@"
