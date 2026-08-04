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
  rm -f -- "$claim/owner" || return 1
  rmdir "$claim"
}

worker_recover_orphaned_job() { # <job-dir>
  local job=$1 file
  worker_claim_owner_alive "$job" && return 1
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

worker_run_with_timeout() { # <seconds> <command> [args...]
  local timeout=$1
  shift
  perl -e '
    use strict;
    use warnings;
    my $seconds = shift @ARGV;
    $seconds =~ /\A\d+\z/ or exit 125;
    my $pid = fork();
    defined $pid or exit 125;
    if ($pid == 0) {
      setpgrp(0, 0) or exit 125;
      exec @ARGV;
      exit 127;
    }
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      $timed_out = 1;
      kill q(TERM), -$pid;
    };
    alarm $seconds;
    my $waited = waitpid($pid, 0);
    alarm 0;
    if ($timed_out) {
      kill q(KILL), -$pid;
      waitpid($pid, 0);
      exit 124;
    }
    exit 125 if $waited < 0;
    exit 128 + ($? & 127) if ($? & 127);
    exit($? >> 8);
  ' "$timeout" "$@"
}

worker_run_job() { # <account-home> <job-dir>
  local account_home=$1 job=$2 root home command command_path git_bin rc
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
  set +e
  worker_run_with_timeout "$FM_REMOTE_JOB_TIMEOUT" "${child_env[@]}" \
    "$command_path" "${argv[@]:1}" < "$job/stdin" > "$stdout_pipe" 2> "$stderr_pipe"
  rc=$?
  wait "$stdout_reader"
  wait "$stderr_reader"
  rm -f -- "$stdout_pipe" "$stderr_pipe"
  set -e
  worker_publish_result "$job" "$rc" || worker_error "could not publish result for ${job##*/}"
}

worker_process_once() { # <account-home>
  local account_home=$1 job id state
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
  trap 'worker_cleanup; exit 0' HUP INT TERM
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
