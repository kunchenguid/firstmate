#!/usr/bin/env bash
# bin/fm-agent-cwd-lib.sh - the ONE owner of "where is this agent actually
# running?".
#
# METHOD OF RECORD (owner ruling 2026-07-25): the AGENT PROCESS's own cwd, read
# from /proc/<pid>/cwd, is the isolation check of record. A session provider's
# pane/surface cwd field is a cheap HINT and never evidence.
#
# Why: a backend's pane cwd can name a completely different process. Observed
# live - a herdr pane listing reported a worker's cwd as the PRIMARY checkout
# while /proc/<pid>/cwd showed the worker correctly inside its own treehouse
# worktree; the pane field had picked up firstmate's own process because both
# share the workspace. A pane read is also frozen at pane-creation time on
# several providers, which is why fm-spawn.sh's worktree-settle poll needs the
# live foreground process rather than the pane record.
#
# Resolution order, most authoritative first:
#   1. the declared agent process - the root-most live process carrying this
#      task's FM_AGENT_TASK marker (bin/fm-worker-isolation-lib.sh). Backend
#      independent, and the only source that survives a restore that re-parents
#      or relabels panes.
#   2. the backend's pane/shell pid, then the deepest descendant of it (the
#      foreground process), read through /proc. Only tmux exposes a verified
#      per-pane pid; herdr, zellij, cmux, and orca do not, so they fall through.
#   3. nothing - the caller may use its own pane-cwd hint, LABELLED as a hint.
#
# Every reader prints one tab-separated verdict record so no call site invents
# its own shape:
#     <source>\t<pid>\t<cwd>
# with source one of:
#   proc         - authoritative, read from the named process
#   unverified   - a process was found but its task identity is incomplete
#   unknown      - no authoritative reading is available here (pid and cwd empty)
#
# On a host without procfs (macOS) step 1 is unavailable and step 2 falls back
# to `lsof -d cwd`; when neither works the verdict is `unknown` rather than a
# pane value silently promoted to evidence.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three,
# and docs/verification/worker-isolation.md owns the per-provider evidence.
#
# This file is sourced by scripts and has no side effects on source.

_FM_AGENT_CWD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_FM_AGENT_CWD_LIB_DIR/fm-process-environ-lib.sh"
# FM_HARNESS_RE and the harness-identity contract have one owner.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$_FM_AGENT_CWD_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$_FM_AGENT_CWD_LIB_DIR/fm-worker-isolation-lib.sh"

FM_AGENT_CWD_MAX_DESCEND=16

fm_agent_pid_is_numeric() {  # <pid>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

fm_agent_ps_pid_exists() {
  local pid=$1 found
  fm_agent_pid_is_numeric "$pid" || return 1
  found=$(ps -p "$pid" -o pid= 2>/dev/null | awk '{print $1; exit}')
  [ "$found" = "$pid" ]
}

# fm_agent_ppid <pid>: the parent pid, from procfs where available and `ps`
# otherwise. /proc/<pid>/status is preferred over /proc/<pid>/stat because a
# process comm containing spaces or parentheses makes stat field offsets unsafe.
fm_agent_ppid() {
  local pid=$1 ppid
  fm_agent_pid_is_numeric "$pid" || return 1
  if [ -r "/proc/$pid/status" ]; then
    ppid=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)
  else
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  fi
  fm_agent_pid_is_numeric "$ppid" || return 1
  printf '%s' "$ppid"
}

# fm_agent_proc_cwd <pid>: the process's real working directory. procfs first;
# `lsof -d cwd` is the documented fallback for hosts without /proc. Returns 1
# rather than guessing when neither can answer.
fm_agent_proc_cwd() {
  local pid=$1 cwd
  fm_agent_pid_is_numeric "$pid" || return 1
  if [ -L "/proc/$pid/cwd" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=
    case "$cwd" in
      /*) printf '%s' "$cwd"; return 0 ;;
    esac
    return 1
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  case "$cwd" in
    /*) printf '%s' "$cwd"; return 0 ;;
  esac
  return 1
}

# fm_agent_environ <pid>: the process environment as newline-separated
# assignments, or 1 when it cannot be read.
#
# The mode bits on /proc/<pid>/environ are not sufficient permission: the kernel
# additionally requires ptrace read access, so a same-uid but privileged process
# passes `-r` and still fails EACCES at open. The redirect therefore has to be
# allowed to fail quietly. Silencing it needs the group form: redirections are
# applied left to right, so a trailing `2>/dev/null` on the same command is set
# up only AFTER the input redirect has already failed and printed to stderr.
fm_agent_environ() {
  local pid=$1
  fm_agent_pid_is_numeric "$pid" || return 1
  fm_process_environ "$pid"
}

# fm_agent_proc_env <pid> <var>: one environment value of a live process, or 1
# when procfs is unavailable, the process is gone, or the variable is unset.
fm_agent_proc_env() {
  local pid=$1 var=$2 value
  [ -n "$var" ] || return 1
  value=$(fm_agent_environ "$pid" | sed -n "s/^$var=//p" | head -1)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_agent_worker_identity_matches() {
  local pid=$1 expected_task=$2 expected_home=${3:-}
  local task role owner
  fm_agent_pid_is_numeric "$pid" || return 1
  task=$(fm_agent_proc_env "$pid" FM_AGENT_TASK 2>/dev/null) || return 1
  role=$(fm_agent_proc_env "$pid" FM_AGENT_ROLE 2>/dev/null) || return 1
  owner=$(fm_agent_proc_env "$pid" FM_AGENT_OWNER_HOME 2>/dev/null) || return 1
  [ "$task" = "$expected_task" ] || return 1
  case "$role" in
    crewmate|secondmate) ;;
    *) return 1 ;;
  esac
  case "$owner" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -z "$expected_home" ] || fm_agent_paths_same "$owner" "$expected_home" || return 1
  fm_agent_worker_home_contract_matches "$pid" "$role" "$owner"
}

fm_agent_proc_start_time() {
  local pid=$1 stat rest start
  fm_agent_pid_is_numeric "$pid" || return 1
  if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    rest=$(printf '%s\n' "$stat" | sed -E 's/^[0-9]+ \(.*\) //')
    start=$(printf '%s\n' "$rest" | awk '{print $20}')
  else
    start=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')
  fi
  [ -n "$start" ] || return 1
  printf '%s' "$start"
}

fm_agent_pid_start_matches() {
  local pid=$1 expected=$2 actual
  [ -n "$expected" ] || return 1
  actual=$(fm_agent_proc_start_time "$pid") || return 1
  [ "$actual" = "$expected" ]
}

fm_agent_paths_same() {
  local left=${1:-} right=${2:-} left_real right_real
  [ -n "$left" ] && [ -n "$right" ] || return 1
  [ "$left" = "$right" ] && return 0
  left_real=$(fm_agent_canonical_dir "$left" 2>/dev/null || printf '%s' "$left")
  right_real=$(fm_agent_canonical_dir "$right" 2>/dev/null || printf '%s' "$right")
  [ "$left_real" = "$right_real" ]
}

fm_agent_worker_home_contract_matches() {
  local pid=$1 role=$2 owner=$3 var value expected
  case "$role" in
    crewmate)
      for var in $FM_WORKER_ISOLATION_HOME_VARS STATE; do
        value=$(fm_agent_proc_env "$pid" "$var" 2>/dev/null || true)
        [ -z "$value" ] || return 1
      done
      return 0
      ;;
    secondmate)
      value=$(fm_agent_proc_env "$pid" FM_HOME 2>/dev/null || true)
      [ -n "$value" ] && fm_agent_paths_same "$value" "$owner" || return 1
      ;;
    *)
      return 1
      ;;
  esac
  for var in $FM_WORKER_ISOLATION_HOME_VARS STATE; do
    case "$var" in
      FM_HOME|FM_ROOT|FM_ROOT_OVERRIDE) expected=$owner ;;
      FM_STATE_OVERRIDE|STATE) expected=$owner/state ;;
      FM_DATA_OVERRIDE) expected=$owner/data ;;
      FM_PROJECTS_OVERRIDE) expected=$owner/projects ;;
      FM_CONFIG_OVERRIDE) expected=$owner/config ;;
      FM_PENDING_REPLY_DIR_OVERRIDE) expected=$owner/state/pending-replies ;;
      *) continue ;;
    esac
    value=$(fm_agent_proc_env "$pid" "$var" 2>/dev/null || true)
    [ -z "$value" ] || fm_agent_paths_same "$value" "$expected" || return 1
  done
  return 0
}

# fm_agent_task_pid_index: one `<task-id>\t<pid>\t<start>\t<home>\t<role>` line per live process that
# declares a task, built from a SINGLE walk of /proc.
#
# Reading one process's environment costs several processes of its own, so a
# caller that asks about MANY tasks builds this index once and hands it back to
# the lookups below. Asking per task instead is O(tasks x processes), which the
# resume sweep pays on the session-start critical path - and the incident it
# exists for had 17 concurrent tasks.
# Returns 2 when the process scan is incomplete; a complete scan returns 0,
# including when no live process declares a task.
fm_agent_task_pid_index() {
  local entry pid env task start home role proc_uid current_uid uncertain=0 rows rest
  current_uid=$(id -u 2>/dev/null) || return 2
  if [ ! -d /proc ]; then
    rows=$(ps -axo uid=,pid= 2>/dev/null) || return 2
    while read -r proc_uid pid rest; do
      [ -n "$proc_uid" ] || continue
      if ! fm_agent_pid_is_numeric "$proc_uid" || ! fm_agent_pid_is_numeric "$pid"; then
        uncertain=1
        continue
      fi
      [ "$proc_uid" = "$current_uid" ] || continue
      if ! env=$(fm_agent_environ "$pid"); then
        fm_agent_ps_pid_exists "$pid" && uncertain=1
        continue
      fi
      task=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_TASK=//p' | head -1)
      [ -n "$task" ] || continue
      start=$(fm_agent_proc_start_time "$pid" 2>/dev/null || true)
      home=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_OWNER_HOME=//p' | head -1)
      role=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_ROLE=//p' | head -1)
      printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$pid" "$start" "$home" "$role"
    done <<< "$rows"
    [ "$uncertain" -eq 0 ] && return 0
    return 2
  fi
  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry#/proc/}
    if ! proc_uid=$(stat -c '%u' "$entry" 2>/dev/null); then
      [ -d "$entry" ] && uncertain=1
      continue
    fi
    if [ -z "$proc_uid" ]; then
      [ -d "$entry" ] && uncertain=1
      continue
    fi
    [ "$proc_uid" = "$current_uid" ] || continue
    if ! env=$(fm_agent_environ "$pid"); then
      [ -d "$entry" ] && uncertain=1
      continue
    fi
    task=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_TASK=//p' | head -1)
    [ -n "$task" ] || continue
    start=$(fm_agent_proc_start_time "$pid" 2>/dev/null || true)
    home=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_OWNER_HOME=//p' | head -1)
    role=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_ROLE=//p' | head -1)
    printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$pid" "$start" "$home" "$role"
  done
  [ "$uncertain" -eq 0 ] && return 0
  return 2
}

fm_agent_task_owner_conflict() {
  local id=$1 index=$2 expected_home=$3 task pid start indexed_home
  [ -n "$id" ] && [ -n "$index" ] && [ -n "$expected_home" ] || return 1
  while IFS=$'\t' read -r task pid start indexed_home _; do
    [ "$task" = "$id" ] || continue
    if ! fm_agent_pid_is_numeric "$pid" || [ -z "$start" ] \
       || ! fm_agent_pid_start_matches "$pid" "$start"; then
      printf '%s' '<unknown>'
      return 0
    fi
    [ -n "$indexed_home" ] || { printf '%s' '<missing>'; return 0; }
    if ! fm_agent_paths_same "$indexed_home" "$expected_home"; then
      printf '%s' "$indexed_home"
      return 0
    fi
  done <<EOF
$index
EOF
  return 1
}

fm_agent_worktree_process_census() {
  local wt=$1 wt_real entry pid cwd cwd_real task proc_uid current_uid rows rest
  local found=1 uncertain=0
  wt_real=$(fm_agent_canonical_dir "$wt") || return 2
  current_uid=$(id -u 2>/dev/null) || return 2
  if [ ! -d /proc ]; then
    rows=$(ps -axo uid=,pid= 2>/dev/null) || return 2
    while read -r proc_uid pid rest; do
      [ -n "$proc_uid" ] || continue
      if ! fm_agent_pid_is_numeric "$proc_uid" || ! fm_agent_pid_is_numeric "$pid"; then
        uncertain=1
        continue
      fi
      [ "$proc_uid" = "$current_uid" ] || continue
      cwd=$(fm_agent_proc_cwd "$pid" 2>/dev/null || true)
      if [ -z "$cwd" ]; then
        fm_agent_ps_pid_exists "$pid" && uncertain=1
        continue
      fi
      cwd_real=$(fm_agent_canonical_dir "$cwd" 2>/dev/null || true)
      [ -n "$cwd_real" ] || { uncertain=1; continue; }
      fm_agent_path_within "$wt_real" "$cwd_real" || continue
      task=$(fm_agent_proc_env "$pid" FM_AGENT_TASK 2>/dev/null || true)
      printf '%s\n' "${task:-unidentified-process-$pid}"
      found=0
    done <<< "$rows"
    [ "$found" -eq 0 ] && return 0
    [ "$uncertain" -eq 1 ] && return 2
    return 1
  fi
  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry#/proc/}
    if ! proc_uid=$(stat -c '%u' "$entry" 2>/dev/null); then
      [ -d "$entry" ] && uncertain=1
      continue
    fi
    if [ -z "$proc_uid" ]; then
      [ -d "$entry" ] && uncertain=1
      continue
    fi
    [ "$proc_uid" = "$current_uid" ] || continue
    cwd=$(fm_agent_proc_cwd "$pid" 2>/dev/null || true)
    if [ -z "$cwd" ]; then
      [ -d "$entry" ] && uncertain=1
      continue
    fi
    cwd_real=$(fm_agent_canonical_dir "$cwd" 2>/dev/null || true)
    [ -n "$cwd_real" ] || { uncertain=1; continue; }
    fm_agent_path_within "$wt_real" "$cwd_real" || continue
    task=$(fm_agent_proc_env "$pid" FM_AGENT_TASK 2>/dev/null || true)
    printf '%s\n' "${task:-unidentified-process-$pid}"
    found=0
  done
  [ "$found" -eq 0 ] && return 0
  [ "$uncertain" -eq 1 ] && return 2
  return 1
}

# fm_agent_pids_for_task <task-id> [pid-index]: every live process whose
# environment declares this task, newline separated. Only the launch command
# itself carries the marker, so the set is the agent plus its descendants.
# A supplied <pid-index> (fm_agent_task_pid_index) is consulted instead of
# walking /proc again; an empty one is a real answer - no process declares a
# task - not a missing argument.
fm_agent_pids_for_task() {
  local id=$1 index indexed_task pid start indexed_home expected_home found=1
  [ -n "$id" ] || return 1
  expected_home=${3:-}
  if [ "$#" -ge 2 ]; then
    index=$2
    while IFS=$'\t' read -r indexed_task pid start indexed_home _; do
      [ "$indexed_task" = "$id" ] || continue
      fm_agent_pid_is_numeric "$pid" || continue
      fm_agent_pid_start_matches "$pid" "$start" || continue
      if [ -n "$expected_home" ]; then
        [ -n "$indexed_home" ] && fm_agent_paths_same "$indexed_home" "$expected_home" || continue
      fi
      printf '%s\n' "$pid"
      found=0
    done <<EOF
$index
EOF
    return "$found"
  fi
  if [ ! -d /proc ]; then
    index=$(fm_agent_task_pid_index) || return 1
    fm_agent_pids_for_task "$id" "$index" "$expected_home"
    return $?
  fi
  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry#/proc/}
    fm_agent_environ "$pid" | grep -qxF "FM_AGENT_TASK=$id" || continue
    if [ -n "$expected_home" ]; then
      indexed_home=$(fm_agent_proc_env "$pid" FM_AGENT_OWNER_HOME 2>/dev/null || true)
      [ -n "$indexed_home" ] && fm_agent_paths_same "$indexed_home" "$expected_home" || continue
    fi
    printf '%s\n' "$pid"
    found=0
  done
  return "$found"
}

# fm_agent_pid_for_task <task-id> [pid-index]: the ROOT-most declared process
# for the task - the launched agent itself rather than one of its tool
# subprocesses, which is the process whose cwd answers "is this worker
# isolated?". The root is the match whose own parent is not also a match.
fm_agent_pid_for_task() {
  local id=$1 matches pid ppid expected_home=${3:-}
  if [ "$#" -ge 2 ]; then
    matches=$(fm_agent_pids_for_task "$id" "$2" "$expected_home") || return 1
  else
    matches=$(fm_agent_pids_for_task "$id") || return 1
    if [ -n "$expected_home" ]; then
      local filtered= indexed_home
      filtered=$(while IFS= read -r pid; do
        indexed_home=$(fm_agent_proc_env "$pid" FM_AGENT_OWNER_HOME 2>/dev/null || true)
        [ -n "$indexed_home" ] && fm_agent_paths_same "$indexed_home" "$expected_home" || continue
        printf '%s\n' "$pid"
      done <<EOF
$matches
EOF
)
      matches=$filtered
      [ -n "$matches" ] || return 1
    fi
  fi
  [ -n "$matches" ] || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    ppid=$(fm_agent_ppid "$pid") || ppid=
    if [ -n "$ppid" ] && printf '%s\n' "$matches" | grep -qxF "$ppid"; then
      continue
    fi
    printf '%s' "$pid"
    return 0
  done <<EOF
$matches
EOF
  # Every match claims a matching parent (a cycle cannot happen, but a race
  # between the scan and a reap can): fall back to the lowest pid seen rather
  # than reporting nothing.
  printf '%s' "$(printf '%s\n' "$matches" | sort -n | head -1)"
}

# fm_agent_tmux_window_id <target>: the STABLE window id behind a tmux target.
#
# A `@<n>` target is already stable and passes straight through. A
# `<session>:<name>` target is resolved by EXACT enumeration and is never handed
# to tmux for resolution, because `display-message -t <unknown-name>` silently
# falls back to the ACTIVE CLIENT's window. A task whose window name was lost or
# auto-renamed would then answer with firstmate's OWN pane pid, whose cwd is the
# primary checkout - a healthy worker reported as a collapse, which is the exact
# false-violation class this library exists to eliminate. bin/fm-spawn.sh pins
# the window name and targets the id for the same reason.
# No exact match returns 1, so the caller reports `unknown` rather than another
# window's evidence.
fm_agent_tmux_window_id() {  # <target>
  local target=${1:-} session window wid
  case "$target" in
    '') return 1 ;;
    @*) printf '%s' "$target"; return 0 ;;
    *:*) session=${target%%:*}; window=${target#*:} ;;
    *) return 1 ;;
  esac
  [ -n "$session" ] && [ -n "$window" ] || return 1
  wid=$(tmux list-windows -t "=$session" -F '#{window_id} #{window_name}' 2>/dev/null \
    | awk -v w="$window" '{ id = $1; $1 = ""; sub(/^ /, ""); if ($0 == w) { print id; exit } }')
  [ -n "$wid" ] || return 1
  printf '%s' "$wid"
}

# fm_agent_backend_shell_pid <backend> <target>: the backend's pane/shell pid.
#
# Provider matrix (verified surfaces, docs/worker-isolation.md owns the record):
#   tmux    #{pane_pid} is a real per-pane shell pid.
#   herdr   the pane API exposes foreground_cwd but no process id.
#   zellij  no per-pane pid is exposed at all (docs/zellij-backend.md).
#   cmux    the control socket exposes no per-surface process id.
#   orca    the terminal endpoint exposes no process id.
# A provider with no pid is not a failure of this function; it means the caller
# has only a hint for tasks that also lack the declared-agent marker.
fm_agent_backend_shell_pid() {
  local backend=$1 target=$2 pid wid
  case "$backend" in
    tmux)
      command -v tmux >/dev/null 2>&1 || return 1
      wid=$(fm_agent_tmux_window_id "$target") || return 1
      pid=$(tmux display-message -p -t "$wid" '#{pane_pid}' 2>/dev/null | tr -d '[:space:]')
      fm_agent_pid_is_numeric "$pid" || return 1
      printf '%s' "$pid"
      ;;
    *) return 1 ;;
  esac
}

# fm_backend_foreground_process_pid <backend> <target>: the process bound to a
# task endpoint, or 1 when this provider cannot expose an authoritative pid.
# A provider path or pane hint is never promoted to occupancy evidence.
fm_backend_foreground_process_pid() {
  local backend=$1 target=$2 shell_pid pid
  shell_pid=$(fm_agent_backend_shell_pid "$backend" "$target") || return 1
  pid=$(fm_agent_harness_pid_below "$shell_pid" 2>/dev/null) \
    || pid=$(fm_agent_foreground_pid "$shell_pid" 2>/dev/null) \
    || pid=$shell_pid
  fm_agent_pid_is_numeric "$pid" || return 1
  fm_agent_proc_cwd "$pid" >/dev/null 2>&1 || return 1
  printf '%s' "$pid"
}

# fm_agent_foreground_pid <pid>: the deepest descendant of <pid> - the process
# actually running in the foreground of that shell. This is what makes a tmux
# reading track `treehouse get`'s subshell, exactly as herdr's foreground_cwd
# does; the pane shell's own cwd never moves.
fm_agent_foreground_pid() {
  local root=$1 table child current depth=0
  fm_agent_pid_is_numeric "$root" || return 1
  table=$(ps -eo pid=,ppid= 2>/dev/null) || return 1
  current=$root
  while [ "$depth" -lt "$FM_AGENT_CWD_MAX_DESCEND" ]; do
    child=$(printf '%s\n' "$table" | awk -v p="$current" '$2 == p {print $1}' | sort -n | tail -1)
    fm_agent_pid_is_numeric "$child" || break
    current=$child
    depth=$((depth + 1))
  done
  printf '%s' "$current"
}

# fm_agent_harness_pid_below <pid>: the deepest descendant of <pid> whose
# command names a verified harness, using the shared FM_HARNESS_RE identity.
# Preferred over the plain foreground process once an agent is running, because
# a transient tool subprocess can sit below the agent with an unrelated cwd.
fm_agent_harness_pid_below() {
  local root=$1 table pid comm args best='' queue next
  fm_agent_pid_is_numeric "$root" || return 1
  table=$(ps -eo pid=,ppid= 2>/dev/null) || return 1
  queue=$root
  local depth=0
  while [ -n "$queue" ] && [ "$depth" -lt "$FM_AGENT_CWD_MAX_DESCEND" ]; do
    next=
    for pid in $queue; do
      comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=
      args=$(ps -o args= -p "$pid" 2>/dev/null) || args=
      if [ -n "$comm" ] \
        && printf '%s' "$(basename "$comm") $args" | grep -qE "$FM_HARNESS_RE"; then
        best=$pid
      fi
      next="$next $(printf '%s\n' "$table" | awk -v p="$pid" '$2 == p {print $1}' | tr '\n' ' ')"
    done
    queue=$next
    depth=$((depth + 1))
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# fm_agent_cwd_verdict <task-id> [backend] [target] [pid-index]
# Print the tab-separated verdict record documented in this file's header.
# Never falls back to a pane value: a caller that wants a hint must ask its
# backend for one and label it as a hint.
# A caller looping over many tasks passes one fm_agent_task_pid_index so the
# declared-agent lookup costs a single /proc walk for the whole loop.
fm_agent_cwd_verdict() {
  local id=${1:-} backend=${2:-} target=${3:-} pid='' cwd shell_pid expected_home=${5:-}
  if [ -n "$id" ]; then
    if [ "$#" -ge 4 ]; then
      pid=$(fm_agent_pid_for_task "$id" "$4" "$expected_home") || pid=
    else
      pid=$(fm_agent_pid_for_task "$id") || pid=
    fi
  fi
  if [ -n "$pid" ]; then
    if [ -n "$id" ] && ! fm_agent_worker_identity_matches "$pid" "$id" "$expected_home"; then
      printf 'unverified\t%s\t' "$pid"
      return 0
    fi
    if cwd=$(fm_agent_proc_cwd "$pid"); then
      printf 'proc\t%s\t%s' "$pid" "$cwd"
      return 0
    fi
  fi
  if [ -n "$backend" ] && [ -n "$target" ] \
    && shell_pid=$(fm_agent_backend_shell_pid "$backend" "$target"); then
    pid=$(fm_agent_harness_pid_below "$shell_pid" 2>/dev/null) \
      || pid=$(fm_agent_foreground_pid "$shell_pid" 2>/dev/null) \
      || pid=$shell_pid
    if [ -n "$id" ] && ! fm_agent_worker_identity_matches "$pid" "$id" "$expected_home"; then
      printf 'unverified\t%s\t' "$pid"
      return 0
    fi
    if cwd=$(fm_agent_proc_cwd "$pid"); then
      printf 'proc\t%s\t%s' "$pid" "$cwd"
      return 0
    fi
  fi
  printf 'unknown\t\t'
}

# fm_agent_verdict_field <record> <source|pid|cwd>
fm_agent_verdict_field() {
  local record=$1 field=$2
  case "$field" in
    source) printf '%s' "${record%%$'\t'*}" ;;
    pid) record=${record#*$'\t'}; printf '%s' "${record%%$'\t'*}" ;;
    cwd) printf '%s' "${record##*$'\t'}" ;;
    *) return 1 ;;
  esac
}

# fm_agent_canonical_dir <path>: physical path of an existing directory, or 1.
fm_agent_canonical_dir() {
  local path=${1:-}
  [ -n "$path" ] || return 1
  [ -d "$path" ] || return 1
  ( cd "$path" 2>/dev/null && pwd -P )
}

# fm_agent_path_within <ancestor> <path>: 0 when <path> is <ancestor> or lives
# under it. Both arguments must already be physical paths.
fm_agent_path_within() {
  local ancestor=${1:-} path=${2:-}
  [ -n "$ancestor" ] && [ -n "$path" ] || return 1
  [ "$ancestor" = "$path" ] && return 0
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}
