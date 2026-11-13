#!/usr/bin/env bash
# fm-task-job.sh - run a worker command that will outlive its turn as a task
# job, so its exit lands in the task's steering inbox and resumes the worker.
#
# bin/fm-task-job-lib.sh owns the job record, completion identity, delivery,
# hold, and recovery contract; this is the command surface.
#
# Usage:
#   fm-task-job.sh start --timeout <seconds> -- <command> [args...]
#       Worker-facing. Resolves the task from $FM_TASK_INBOX, which
#       bin/fm-spawn.sh exports into every task launch, and the spawn
#       generation from that task's metadata. Records the job and starts a
#       detached runner in a new session, so neither the turn ending nor the
#       harness stopping its own process group stops the command. Prints the
#       job id, the output path, and `until: <YYYY-MM-DDTHH:MMZ>` (start plus
#       timeout, rounded up to the minute) for the worker's `paused:`
#       declaration, then returns. When the job finishes, or passes its
#       timeout and is stopped, the runner publishes its exit record. The
#       watcher delivers the completion and rings unless the task is held.
#       If the runner exits during startup, start returns 1 and names the
#       retained job directory; use the recovery contract above to assess it.
#   fm-task-job.sh stop-all <state-dir> <task-id>
#       Stop every live job of the task without delivering anything.
#       bin/fm-teardown.sh runs it before it removes the task's inbox.
#   fm-task-job.sh _run <state-dir> <task-id> <job-dir>
#       Internal: the detached runner that start launches.
#
# The timeout is required, from 1 to 604800 seconds, so every job is bounded,
# within the process-group limit that bin/fm-task-job-lib.sh states.
# Leading zeros retain decimal meaning.
# Exit codes: 0 ok, 1 refused or failed, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'fm-task-job: %s\n' "$1" >&2
  exit 1
}

usage() {
  [ -z "${1:-}" ] || printf 'fm-task-job: %s\n' "$1" >&2
  echo "usage: fm-task-job.sh start --timeout <seconds> -- <command> [args...] | stop-all <state-dir> <task-id>" >&2
  exit 2
}

# Point the sourced libraries at the task's own state directory before they
# load, so none of them resolves or creates another home's state. These stay
# unexported so the job's command inherits the worker's environment unchanged.
use_state() {  # <state-dir>
  [ -d "$1" ] || die "state directory is missing: $1"
  FM_STATE_OVERRIDE="$1"
  if [ -z "${FM_HOME:-}" ] && [ "${1##*/}" = state ]; then
    FM_HOME="${1%/*}"
  fi
  # shellcheck source=bin/fm-task-job-lib.sh
  . "$SCRIPT_DIR/fm-task-job-lib.sh"
}

valid_task() {  # <task-id>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

STOP_REQUESTED=0

cmd_run() {  # <state-dir> <task-id> <job-dir>
  local dir=$3 a deadline limit status=0 outcome=exited RUN_CHILD owner rc child_start child_rc
  local argv=()
  trap 'STOP_REQUESTED=1' TERM INT
  [ -f "$dir/job" ] && [ -f "$dir/argv" ] || exit 1
  # Never restart a job that already has a recorded terminal outcome.
  [ ! -e "$dir/exit" ] || exit 0
  [ "$(fm_meta_get "$dir/job" stopped)" != 1 ] || exit 0
  while IFS= read -r -d '' a; do
    argv+=("$a")
  done < "$dir/argv"
  [ "${#argv[@]}" -gt 0 ] || exit 1
  deadline=$(fm_meta_get "$dir/job" deadline)
  case "$deadline" in ''|*[!0-9]*) exit 1 ;; esac
  fm_current_pid owner || exit 1
  fm_task_job_write_record "$dir/runner" "pid=$owner" \
    "start=$(fm_pid_start_time "$owner")" || exit 1
  [ "$STOP_REQUESTED" = 0 ] || exit 143
  "${argv[@]}" > "$dir/output" 2>&1 < /dev/null &
  RUN_CHILD=$!
  fm_task_job_write_record "$dir/child" "pid=$RUN_CHILD" \
    "start=$(fm_pid_start_time "$RUN_CHILD" || true)" || true
  child_start=$(fm_meta_get "$dir/child" start)
  limit=$((SECONDS + deadline - $(date +%s)))
  while :; do
    rc=0
    fm_task_job_group_members "$owner" "$owner" >/dev/null || rc=$?
    child_rc=0
    fm_task_job_proc_state "$RUN_CHILD" "$child_start" || child_rc=$?
    [ "$rc" -ne 1 ] || [ "$child_rc" -ne 1 ] || break
    if [ "$STOP_REQUESTED" = 1 ] || [ "$SECONDS" -ge "$limit" ]; then
      [ "$STOP_REQUESTED" = 1 ] || outcome='timed-out'
      if ! fm_task_job_stop_owned_group "$owner" "$owner"; then
        sleep 1
        continue
      fi
      # The direct command may have made itself a group leader. Only its
      # recorded identity proves ownership of that additional group.
      child_rc=0
      fm_task_job_proc_state "$RUN_CHILD" "$child_start" || child_rc=$?
      if [ "$child_rc" -eq 2 ] || { [ "$child_rc" -eq 0 ] && ! fm_task_job_stop_owned_group "$RUN_CHILD"; }; then
        sleep 1
        continue
      fi
      break
    fi
    sleep 1
  done
  wait "$RUN_CHILD" 2>/dev/null || status=$?
  if [ "$STOP_REQUESTED" = 1 ]; then
    exit 143
  fi
  fm_task_job_publish_exit "$dir" "$outcome" "$status" || true
}

cmd_start() (
  local timeout='' inbox state task meta gen root id dir n=0 started deadline runner rc i lock
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) [ "$#" -ge 2 ] || usage "--timeout needs a value"; timeout=$2; shift 2 ;;
      --timeout=*) timeout=${1#*=}; shift ;;
      --) shift; break ;;
      *) usage "unknown start argument: $1" ;;
    esac
  done
  [ "$#" -ge 1 ] || usage "start needs a command after --"
  case "$timeout" in ''|*[!0-9]*) usage "--timeout needs a whole number of seconds" ;; esac
  while [ "${timeout#0}" != "$timeout" ]; do timeout=${timeout#0}; done
  timeout=${timeout:-0}
  if [ "${#timeout}" -gt 6 ] || [ "$timeout" -lt 1 ] || [ "$timeout" -gt 604800 ]; then
    usage "--timeout must be from 1 to 604800 seconds"
  fi

  inbox=${FM_TASK_INBOX:-}
  [ -n "$inbox" ] || die "FM_TASK_INBOX is not set; run this from a Firstmate task worker, whose launch exports it"
  case "$inbox" in /*.inbox) ;; *) die "FM_TASK_INBOX must be an absolute path ending in .inbox: $inbox" ;; esac
  state=${inbox%/*}
  task=${inbox##*/}
  task=${task%.inbox}
  valid_task "$task" || die "unsupported task id in FM_TASK_INBOX: $task"
  use_state "$state"
  meta="$state/$task.meta"
  lock=$(fm_meta_lock_path "$meta") || die "cannot resolve the task lock"
  fm_lock_acquire_wait "$lock" || die "cannot lock the task"
  trap 'fm_lock_release "$lock"' EXIT
  trap 'exit 143' TERM INT
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "no task metadata for $task at $meta; the task may have been retired"
  gen=$(fm_meta_get "$meta" spawn_gen)
  [ -n "$gen" ] || die "the metadata for $task records no spawn_gen, so its completion cannot be keyed"

  root=$(fm_task_job_root "$state" "$task")
  mkdir -p "$root" || die "cannot create the job directory under $root"
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  dir="$root/$id"
  until mkdir "$dir" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || die "cannot allocate a job directory under $root"
    dir="$root/$id-$n"
  done
  started=$(date +%s)
  deadline=$((started + timeout))
  fm_task_job_write_record "$dir/job" "task=$task" "gen=$gen" \
    "timeout=$timeout" "started=$started" "deadline=$deadline" \
    || { rm -rf "$dir"; die "cannot record the job under $dir"; }
  printf '%s\0' "$@" > "$dir/argv" || { rm -rf "$dir"; die "cannot record the command under $dir"; }

  # A new session detaches the runner from the harness's terminal and process
  # group; closed standard streams keep the harness from waiting on it.
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  perl -MPOSIX -e 'defined(POSIX::setsid()) or exit 125; exec { $ARGV[0] } @ARGV or exit 127' -- \
    "$BASH" "$SCRIPT_DIR/fm-task-job.sh" _run "$state" "$task" "$dir" \
    < /dev/null >> "$dir/runner.log" 2>&1 &
  runner=$!

  # Confirm the runner reached its command before reporting the job started.
  i=0
  while [ ! -f "$dir/child" ] && [ ! -f "$dir/exit" ]; do
    rc=0
    fm_task_job_runner_state "$dir" || rc=$?
    if [ "$rc" -eq 1 ] || { [ "$rc" -eq 2 ] && ! kill -0 "$runner" 2>/dev/null; }; then
      die "the job runner exited during startup; recovery records retained at $dir"
    fi
    [ "$i" -lt 100 ] || break
    sleep 0.1
    i=$((i + 1))
  done

  printf 'job: %s\n' "${dir##*/}"
  printf 'output: %s/output\n' "$dir"
  printf 'until: %s\n' "$(fm_task_job_utc_minute "$(( (deadline + 59) / 60 * 60 ))")"
)

cmd="${1:-}"
[ "$#" -eq 0 ] || shift
case "$cmd" in
  start)
    cmd_start "$@"
    ;;
  stop-all)
    [ "$#" -eq 2 ] || usage "stop-all needs <state-dir> <task-id>"
    valid_task "$2" || die "unsupported task id: $2"
    use_state "$1"
    fm_task_job_stop_all "$1" "$2"
    ;;
  _run)
    [ "$#" -eq 3 ] || usage "_run needs <state-dir> <task-id> <job-dir>"
    valid_task "$2" || exit 1
    use_state "$1"
    cmd_run "$1" "$2" "$3"
    ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    ;;
  *)
    usage
    ;;
esac
