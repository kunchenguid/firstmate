#!/usr/bin/env bash
# fm-task-job-lib.sh - the ONE owner of the task-job contract: a command a
# worker leaves running across a turn end, whose exit becomes a durable record
# in that task's steering inbox.
#
# Why: a harness background terminal can finish while its worker has no turn,
# and nothing then starts one. Codex records such an exit against the turn that
# already ended and waits for input, and a declared `paused:` wait is only
# rechecked at its `until` backstop through a supervisor's judgement, which
# cannot see that the command finished. For commands launched as task jobs,
# bin/fm-task-job.sh's runner is the command's parent, so the exit
# is a kernel fact it observes directly, and delivery reuses the steering inbox
# (bin/fm-task-inbox-lib.sh), whose acknowledgement move ends each job's own
# delivery ladder. The runner waits until its own process group has no other
# live members and the direct command's recorded identity has ended, even if
# that command leaves the runner's group. Only then does it publish the exit
# record with the command's exit status. At the deadline it stops its group
# and the direct command's own group while that command's recorded identity
# still proves ownership; an unproven group is never signaled.
# Limit: a command that moves itself into another process group, or exits
# leaving a background descendant running, is not guaranteed to be stopped at
# the deadline or on cleanup, and its job can be published as finished while
# that descendant still runs. The refusal to signal a group whose ownership
# cannot be proven is unchanged by this limit.
# Harness-native background commands and guardian outcomes are not covered.
#
# Layout under <state-dir>/<task>.inbox/jobs/<job-id>/ (teardown removes the
# inbox, and with it every job record):
#   job        key=value: task, gen (the task's spawn_gen at start), timeout,
#              started, deadline; stopped=1 appended after confirmed cleanup
#   argv       the command, NUL-delimited
#   runner     key=value: pid and start (fm_pid_start_time) of the detached runner,
#              written by the runner before it starts the command
#   child      key=value: pid and start of the direct command, which may leave
#              the runner's group; written by the runner once the command runs
#   output     the command's combined stdout and stderr
#   exit       key=value: outcome (exited, timed-out, or lost), status, ended;
#              published once by an exclusive link, so its presence means the
#              job is over and no later writer can replace it
#   delivered  the inbox record name the completion was delivered as
#   delivery   key=value: count and last delivery attempt epoch
#   busy       key=value: count of consecutive busy deferrals
#   escalated  key=value: record already surfaced as stale
#
# Identity: a completion is keyed by its task, the spawn generation that started
# the job, and the job id, and all three are in the record body, so the inbox's
# exact-body dedup lands every redelivery of one completion on one record, even
# after the worker acknowledged it. A job whose task metadata or job directory
# is gone (teardown) is never delivered and never recreates the inbox.
#
# Watcher-owned delivery: fm_task_job_reconcile enqueues a hold-aware record
# through fm_task_job_deliver (bin/fm-task-inbox-lib.sh owns its format), and
# bin/fm-watch.sh's task_job_check owns its doorbell attempts and stale wakes.
# fm_task_job_task_held reads the task's own open status decisions, its declared
# captain-held wait, and its backlog captain hold through fm-captain-hold.sh,
# in the watcher's own home and data context, never the runner's environment.
# A failed backlog hold lookup suppresses rings and escalation and appends a
# status diagnostic once per distinct error; delivery can resume after recovery.
# An unheld completion is due its first ring in the delivering poll, subject to
# the endpoint and busy guards. While held it consumes no delivery attempts or
# busy deferrals; after release its delivery resumes. Each job owns its count, spacing,
# busy deferrals and escalation, independently of every steer and other job,
# using the inbox grace and budget tunables until acknowledgement.
# A deliberate hold therefore never
# auto-resumes, while a worker's own `paused:` wait is woken.
#
# Recovery (fm_task_job_reconcile, run by bin/fm-watch.sh on every poll for each
# recorded task): a completion captured but not delivered is delivered, and a
# job whose runner is gone without an exit record is reported as
# unrecoverable without signaling a group whose ownership cannot be proven.
# A missing exit record does not establish that the command stopped.
# Recovery and hold-lookup diagnostics are
# comment status lines that preserve declared waits and open decisions.
# fm_task_job_stop_all is teardown's stop for a task's live jobs, including
# secondmate children, before removing their worktrees, metadata or homes.
# A failed stop retains those resources. A finished job whose recorded runner
# identity has ended is skipped before inspecting or signaling its historical
# process group; a matching live runner is still stopped. Confirmed cleanup
# appends stopped=1 to the existing job record, so retries skip that job and
# neither recovery nor delivery produces a completion for it. An unconfirmed
# job without an exit record still refuses cleanup when ownership is unproven.
# Concurrent job retirement is quiet at watcher bookkeeping boundaries, while
# write failures for surviving job records remain errors. The lifecycle and
# delivery regressions are in tests/fm-task-job.test.sh.
#
# Tunables (env):
#   FM_TASK_JOB_START_GRACE_SECS  default 30; how long a job may lack its runner
#                                 record before reconcile reports it unrecoverable
#   FM_TASK_JOB_KILL_GRACE_SECS   default 5; TERM-to-KILL grace when stopping

_FM_TASK_JOB_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_TASK_JOB_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_TASK_JOB_LIB_DIR=.
# A consumer that already loaded these keeps its copy; re-sourcing them would
# re-run their source-time setup in the middle of that consumer.
if ! command -v fm_task_inbox_write_idempotent >/dev/null 2>&1; then
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "${_FM_TASK_JOB_LIB_DIR:-/}/fm-task-inbox-lib.sh"
fi
if ! command -v status_own_open_decisions >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "${_FM_TASK_JOB_LIB_DIR:-/}/fm-classify-lib.sh"
fi
unset _FM_TASK_JOB_LIB_DIR

FM_TASK_JOB_START_GRACE_DEFAULT=30
FM_TASK_JOB_KILL_GRACE_DEFAULT=5

fm_task_job_secs() {  # <value> <default>
  local value=$1
  case "$value" in ''|*[!0-9]*) printf '%s' "$2"; return ;; esac
  while [ "${value#0}" != "$value" ]; do value=${value#0}; done
  value=${value:-0}
  if [ "${#value}" -gt 6 ] || [ "$value" -gt 604800 ]; then
    printf '%s' "$2"
  else
    printf '%s' "$value"
  fi
}

fm_task_job_root() {  # <state-dir> <task-id>
  printf '%s/jobs' "$(fm_task_inbox_dir "$1" "$2")"
}

# UTC minute stamp for an epoch, in the `until` shape the declared-wait
# vocabulary reads (bin/fm-classify-lib.sh status_paused_until).
fm_task_job_utc_minute() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null
}

# 0 when <pid> is still the process that started at <start>, 1 when it is
# provably gone or reused, 2 when its identity cannot be read. Unknown is never
# read as gone, so a transient ps failure cannot publish a live job as lost.
fm_task_job_proc_state() {  # <pid> <start>
  local have
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "$2" ] || return 2
  have=$(fm_pid_start_time "$1") || return 2
  [ "$have" = "$2" ] || return 1
  return 0
}

# Runner state of one job: 0 running (or unknown), 1 gone, 2 never recorded.
fm_task_job_runner_state() {  # <job-dir>
  local rc=0
  [ -f "$1/runner" ] || return 2
  fm_task_job_proc_state "$(fm_meta_get "$1/runner" pid)" "$(fm_meta_get "$1/runner" start)" || rc=$?
  [ "$rc" -ne 1 ] || return 1
  return 0
}

# Write a key=value record atomically: temp file, then rename.
fm_task_job_write_record() {  # <path> <key=value>...
  local path=$1 tmp kv
  shift
  tmp=$(mktemp "${path%/*}/.record.XXXXXX") || return 1
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Publish the job's one exit record. The exclusive link makes the first writer
# win, so concurrent publication can never replace an existing result.
fm_task_job_publish_exit() {  # <job-dir> <outcome> <status>
  local dir=$1 tmp rc=0
  [ -d "$dir" ] || return 1
  [ ! -e "$dir/exit" ] || return 1
  tmp=$(mktemp "$dir/.exit.XXXXXX") || return 1
  printf 'outcome=%s\nstatus=%s\nended=%s\n' "$2" "$3" "$(date +%s)" > "$tmp" \
    && ln "$tmp" "$dir/exit" 2>/dev/null || rc=1
  rm -f "$tmp"
  return "$rc"
}

fm_task_job_group_members() {
  local snapshot probe
  case "$1" in ''|*[!0-9]*|0|1) return 2 ;; esac
  fm_current_pid probe || return 2
  snapshot=$(LC_ALL=C exec perl -MPOSIX -e 'defined(POSIX::setsid()) or exit 125; exec "ps", "-axo", "pid=,pgid=,stat=" or exit 127' 2>/dev/null) || return 2
  awk -v group="$1" -v owner="${2:-}" -v probe="$probe" '
    $2 == group && $1 != owner && $1 != probe && $3 !~ /^Z/ { print $1; live = 1 }
    END { exit !live }
  ' <<< "$snapshot"
}

fm_task_job_stop_owned_group() {
  local group=$1 exclude=${2:-} members pid grace limit rc=0 i=0
  members=$(fm_task_job_group_members "$group" "$exclude") || rc=$?
  [ "$rc" -ne 1 ] || return 0
  [ "$rc" -eq 0 ] || return 1
  while IFS= read -r pid; do
    kill -TERM "$pid" 2>/dev/null || true
  done <<< "$members"
  grace=$(fm_task_job_secs "${FM_TASK_JOB_KILL_GRACE_SECS:-}" "$FM_TASK_JOB_KILL_GRACE_DEFAULT")
  limit=$((SECONDS + grace))
  while [ "$SECONDS" -lt "$limit" ]; do
    rc=0
    fm_task_job_group_members "$group" "$exclude" >/dev/null || rc=$?
    [ "$rc" -ne 1 ] || return 0
    [ "$rc" -eq 0 ] || return 1
    sleep 0.1
  done
  while [ "$i" -lt 100 ]; do
    rc=0
    members=$(fm_task_job_group_members "$group" "$exclude") || rc=$?
    [ "$rc" -ne 1 ] || return 0
    [ "$rc" -eq 0 ] || return 1
    while IFS= read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
    done <<< "$members"
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

fm_task_job_unrecoverable() {
  local dir=$1 inbox state task line
  inbox=${dir%/jobs/*}
  state=${inbox%/*}
  task=${inbox##*/}
  task=${task%.inbox}
  line="# task-job: unrecoverable job ${dir##*/}: runner ownership cannot be proven; refusing to signal its process group ($dir)"
  printf '%s\n' "$line" >&2
  if [ -f "$state/$task.status" ] && ! status_event_recorded "$state/$task.status" "$line"; then
    printf '%s\n' "$(status_stamp_line "$line")" >> "$state/$task.status"
  fi
  return 1
}

fm_task_job_stop_runner() {
  local dir=$1 pid start rc=0 grace limit
  [ "$(fm_meta_get "$dir/job" stopped)" != 1 ] || return 0
  if [ ! -f "$dir/runner" ]; then
    [ ! -f "$dir/exit" ] || return 0
    fm_task_job_unrecoverable "$dir"
    return 1
  fi
  pid=$(fm_meta_get "$dir/runner" pid)
  start=$(fm_meta_get "$dir/runner" start)
  fm_task_job_proc_state "$pid" "$start" || rc=$?
  if [ "$rc" -eq 1 ] && [ -f "$dir/exit" ]; then
    return 0
  fi
  [ "$rc" -eq 0 ] || { fm_task_job_unrecoverable "$dir"; return 1; }
  rc=0
  fm_task_job_group_members "$pid" >/dev/null || rc=$?
  if [ "$rc" -eq 1 ]; then
    [ -f "$dir/job" ] && printf 'stopped=1\n' >> "$dir/job"
    return
  fi
  [ "$rc" -eq 0 ] || return 1
  rc=0
  fm_task_job_proc_state "$pid" "$start" || rc=$?
  [ "$rc" -eq 0 ] || { fm_task_job_unrecoverable "$dir"; return 1; }
  kill -TERM -- "-$pid" 2>/dev/null || true
  grace=$(fm_task_job_secs "${FM_TASK_JOB_KILL_GRACE_SECS:-}" "$FM_TASK_JOB_KILL_GRACE_DEFAULT")
  limit=$((SECONDS + grace + 15))
  while [ "$SECONDS" -lt "$limit" ]; do
    rc=0
    fm_task_job_group_members "$pid" >/dev/null || rc=$?
    if [ "$rc" -eq 1 ]; then
      [ -f "$dir/job" ] && printf 'stopped=1\n' >> "$dir/job"
      return
    fi
    [ "$rc" -eq 0 ] || return 1
    sleep 0.1
  done
  rc=0
  fm_task_job_proc_state "$pid" "$start" || rc=$?
  [ "$rc" -eq 0 ] || fm_task_job_unrecoverable "$dir"
  return 1
}

# The completion notice. Every value comes from the job's own records, so the
# same completion always yields the same body and dedups onto one record.
fm_task_job_message() {  # <job-dir>
  local dir=$1 id task gen started outcome status ended result
  [ -f "$dir/job" ] && [ -f "$dir/exit" ] || return 1
  id=${dir##*/}
  task=$(fm_meta_get "$dir/job" task)
  gen=$(fm_meta_get "$dir/job" gen)
  started=$(fm_meta_get "$dir/job" started)
  outcome=$(fm_meta_get "$dir/exit" outcome)
  status=$(fm_meta_get "$dir/exit" status)
  ended=$(fm_meta_get "$dir/exit" ended)
  case "$outcome" in
    exited) result="the command exited with status $status" ;;
    timed-out) result="the command passed its $(fm_meta_get "$dir/job" timeout)-second timeout and was stopped (status $status)" ;;
    lost) result="its runner stopped before recording an exit, so the command's result is unknown; any command still running was stopped" ;;
    *) return 1 ;;
  esac
  printf 'Task job %s finished: %s.\n' "$id" "$result"
  printf 'Task: %s; started by worker generation %s.\n' "$task" "$gen"
  printf 'Started: %s; ended: %s.\n' "$(fm_task_job_utc_minute "$started")" "$(fm_task_job_utc_minute "$ended")"
  printf 'Output: %s/output\n' "$dir"
  printf '%s\n' "This record reports your own task job's result; it is not a new instruction. Read the output, record the result, and continue under your current instructions; a decision or hold you are waiting on still applies."
}

fm_task_job_task_held() {
  local state=$1 task=$2 rc=0 error line
  if [ -n "$(status_own_open_decisions "$state/$task.status")" ] \
    || status_is_captain_held "$(status_declared_wait_line "$state/$task.status")"; then
    return 0
  fi
  error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" \
    "$FM_WAKE_LIB_DIR/fm-captain-hold.sh" open "$task" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    line="# task-job: captain hold lookup failed (exit $rc): ${error//$'\n'/ }"
    if ! status_event_recorded "$state/$task.status" "$line"; then
      printf '%s\n' "$(status_stamp_line "$line")" >> "$state/$task.status"
    fi
  fi
  [ "$rc" -ne 1 ]
}

# Deliver one finished job into its task's steering inbox, at most once per
# completion. The watcher owns delivery and each job's ringing ladder.
# Fails without writing when the task or job is gone.
fm_task_job_deliver() (
  local state=$1 task=$2 dir=$3 meta inbox msg rec lock
  meta="$state/$task.meta"
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  trap 'fm_lock_release "$lock"' EXIT
  trap 'exit 143' TERM INT
  inbox=$(fm_task_inbox_dir "$state" "$task")
  [ -d "$dir" ] && [ -f "$dir/exit" ] || return 1
  [ "$(fm_meta_get "$dir/job" stopped)" != 1 ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -d "$inbox" ] || return 1
  msg=$(fm_task_job_message "$dir") || return 1
  rec=$(fm_task_inbox_write_idempotent "$state" "$task" "$msg" hold-aware) || return 1
  fm_task_job_write_record "$dir/delivered" "record=${rec##*/}" || true
  return 0
)

fm_task_job_due_action() {  # <job-dir>
  local dir=$1 rec count last now
  [ "$(fm_meta_get "$dir/job" stopped)" != 1 ] || { printf quiet; return; }
  rec=$(fm_meta_get "$dir/delivered" record)
  rec="${dir%/jobs/*}/$rec"
  [ -f "$rec" ] && [ ! -f "$dir/escalated" ] || { printf quiet; return; }
  count=$(fm_meta_get "$dir/delivery" count)
  last=$(fm_meta_get "$dir/delivery" last)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now=$(date +%s)
  if [ "$count" -gt 0 ] && [ "$((now - last))" -lt "$(fm_task_inbox_grace_secs)" ]; then
    printf quiet
  elif [ "$count" -ge "$(fm_task_inbox_ring_max)" ]; then
    printf 'escalate %s %s' "$rec" "$count"
  else
    printf 'ring %s %s' "$rec" "$count"
  fi
}

# The watcher's per-poll recovery for one task (see the header). Cheap when the
# task has no job directory.
fm_task_job_reconcile() {  # <state-dir> <task-id>
  local root dir rc grace
  root=$(fm_task_job_root "$1" "$2")
  [ -d "$root" ] || return 0
  grace=$(fm_task_job_secs "${FM_TASK_JOB_START_GRACE_SECS:-}" "$FM_TASK_JOB_START_GRACE_DEFAULT")
  for dir in "$root"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    [ "$(fm_meta_get "$dir/job" stopped)" != 1 ] || continue
    [ ! -f "$dir/delivered" ] || continue
    rc=0
    fm_task_job_runner_state "$dir" || rc=$?
    [ "$rc" -ne 0 ] || continue
    if [ ! -f "$dir/exit" ]; then
      if [ "$rc" -eq 2 ]; then
        [ -f "$dir/job" ] && [ "$(fm_path_age "$dir/job")" -ge "$grace" ] || continue
      fi
      fm_task_job_unrecoverable "$dir" || true
      continue
    fi
    fm_task_job_deliver "$1" "$2" "$dir" || true
  done
  return 0
}

# Stop every live job of a task without delivering anything through its runner.
# Teardown runs this before it removes the inbox.
fm_task_job_stop_all() {  # <state-dir> <task-id>
  local root dir failed=0
  root=$(fm_task_job_root "$1" "$2")
  [ -d "$root" ] || return 0
  for dir in "$root"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    fm_task_job_stop_runner "$dir" || failed=1
  done
  return "$failed"
}
