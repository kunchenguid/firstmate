#!/usr/bin/env bash
# Register and observe detached background work that has no agent endpoint.
#
# Usage:
#   fm-background-work.sh register <id> --description <text> --task <task> --pid <pid>
#     --started-at <UTC-RFC3339> [--expected-finish-at <UTC-RFC3339>]
#     [--cwd <directory>] [--stale-after <seconds>] [--progress-timeout <seconds>]
#     --progress <argv>...
#   fm-background-work.sh list [--json]
#   fm-background-work.sh retire <id>
#
# register adopts an already-running process. It records both the PID and the
# process identity observed at registration, so a later process at the same PID
# is reported dead rather than mistaken for the registered work. The progress
# command is stored as an argv vector and run directly, from the registered
# working directory, with no shell interpretation. Its stdout must be one
# non-empty printable line of at most 512 bytes. Each probe is bounded by
# --progress-timeout (default 2 seconds).
#
# list observes every durable record under state/background-work/. A successful
# progress value is compared with the prior observation. A changed value is
# progressing; an unchanged value remains progressing only until --stale-after
# (default 300 seconds) elapses, then reads stalled. The first good observation,
# a failed/timed-out/malformed progress command, an unreadable process identity,
# a missing working directory, or an observation race reads unknown. A missing
# process, zombie, or identity mismatch reads dead and remains listed until
# retire, so quiet death cannot look like absence or health. List probes at most
# 32 records concurrently under one 3-second collection budget. Every record is
# still emitted; work not completed within the budget reads unknown, and the
# collection metadata discloses incomplete or capped probing. Three seconds keeps
# this below the five-second fleet snapshot collection budget while allowing the
# normal two-second per-probe bound plus process startup and JSON encoding.
#
# `list --json` emits schema fm-background-work-list.v1. This is the supported
# machine interface for dashboards; consumers never read the private records.
# The default output is a tab-separated human view of the same document.
#
# This command provides visibility only. It does not supervise, signal, restart,
# recover, or wake for registered work, and the watcher never depends on it.
# retire removes only the visibility record; it never signals the process.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$STATE/background-work"
DEFAULT_STALE_AFTER=${FM_BACKGROUND_WORK_STALE_AFTER:-300}
DEFAULT_PROGRESS_TIMEOUT=${FM_BACKGROUND_WORK_PROGRESS_TIMEOUT:-2}
COLLECTION_BUDGET=${FM_BACKGROUND_WORK_COLLECTION_BUDGET:-3}
COLLECTION_MAX_PROBES=${FM_BACKGROUND_WORK_COLLECTION_MAX_PROBES:-32}
COLLECTION_PROBE_TIMEOUT=${FM_BACKGROUND_WORK_COLLECTION_PROBE_TIMEOUT:-2}
MAX_PROGRESS_BYTES=512
RUNTIME_LIBS_LOADED=0

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

load_runtime_libs() {
  [ "$RUNTIME_LIBS_LOADED" -eq 1 ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  RUNTIME_LIBS_LOADED=1
}

valid_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

safe_text() {
  local value=$1 max=$2
  [ -n "$value" ] || return 1
  [ "${#value}" -le "$max" ] || return 1
  ! printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'
}

safe_arg() {
  local value=$1
  [ "${#value}" -le 4096 ] || return 1
  ! printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'
}

valid_time() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

positive_integer "$COLLECTION_BUDGET" || die "FM_BACKGROUND_WORK_COLLECTION_BUDGET must be a positive integer"
positive_integer "$COLLECTION_MAX_PROBES" || die "FM_BACKGROUND_WORK_COLLECTION_MAX_PROBES must be a positive integer"
positive_integer "$COLLECTION_PROBE_TIMEOUT" || die "FM_BACKGROUND_WORK_COLLECTION_PROBE_TIMEOUT must be a positive integer"
[ "$COLLECTION_PROBE_TIMEOUT" -lt "$COLLECTION_BUDGET" ] \
  || die "FM_BACKGROUND_WORK_COLLECTION_PROBE_TIMEOUT must be less than the collection budget"

meta_value() { # <file> <key>
  awk -v key="$2" '
    index($0, key "=") == 1 { count++; value=substr($0, length(key) + 2) }
    END { if (count == 1) print value; else exit 1 }
  ' "$1" 2>/dev/null
}

process_is_zombie() { # <pid>; 0 zombie, 1 not zombie, 2 unknown
  local pid=$1 proc_root stat_line state
  local -a fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 2
    read -r -a fields <<< "${stat_line##*)}"
    [ "${#fields[@]}" -ge 1 ] || return 2
    [ "${fields[0]}" = Z ] && return 0
    return 1
  fi
  state=$(LC_ALL=C ps -p "$pid" -o stat= 2>/dev/null) || return 2
  case "$state" in
    [Zz]*) return 0 ;;
    '') return 2 ;;
    *) return 1 ;;
  esac
}

resolve_executable() { # <command> <cwd>
  local command_name=$1 cwd=$2 candidate dir base
  case "$command_name" in
    */*)
      case "$command_name" in
        /*) candidate=$command_name ;;
        *) candidate="$cwd/$command_name" ;;
      esac
      dir=${candidate%/*}
      base=${candidate##*/}
      dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
      candidate="$dir/$base"
      ;;
    *) candidate=$(command -v -- "$command_name" 2>/dev/null) || return 1 ;;
  esac
  [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

register_work() {
  local id=${1-} description='' task='' pid='' started_at='' expected_finish_at=''
  local cwd stale_after=$DEFAULT_STALE_AFTER progress_timeout=$DEFAULT_PROGRESS_TIMEOUT
  local current_identity resolved stage record tmp arg zombie_rc
  local -a progress=()
  shift || true
  valid_id "$id" || die "invalid background-work id: $id"
  cwd=$(pwd -P) || die "cannot resolve the current working directory"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --description) [ "$#" -ge 2 ] || die "--description needs a value"; description=$2; shift 2 ;;
      --task) [ "$#" -ge 2 ] || die "--task needs a value"; task=$2; shift 2 ;;
      --pid) [ "$#" -ge 2 ] || die "--pid needs a value"; pid=$2; shift 2 ;;
      --started-at) [ "$#" -ge 2 ] || die "--started-at needs a value"; started_at=$2; shift 2 ;;
      --expected-finish-at) [ "$#" -ge 2 ] || die "--expected-finish-at needs a value"; expected_finish_at=$2; shift 2 ;;
      --cwd) [ "$#" -ge 2 ] || die "--cwd needs a value"; cwd=$2; shift 2 ;;
      --stale-after) [ "$#" -ge 2 ] || die "--stale-after needs a value"; stale_after=$2; shift 2 ;;
      --progress-timeout) [ "$#" -ge 2 ] || die "--progress-timeout needs a value"; progress_timeout=$2; shift 2 ;;
      --progress) shift; progress=("$@"); break ;;
      *) die "unknown register option: $1" ;;
    esac
  done

  safe_text "$description" 240 || die "description must be 1-240 printable characters"
  safe_text "$task" 160 || die "task must be 1-160 printable characters"
  case "$pid" in ''|*[!0-9]*|0) die "pid must be a positive integer" ;; esac
  valid_time "$started_at" || die "started-at must be UTC RFC3339 (YYYY-MM-DDTHH:MM:SSZ)"
  [ -z "$expected_finish_at" ] || valid_time "$expected_finish_at" \
    || die "expected-finish-at must be UTC RFC3339 (YYYY-MM-DDTHH:MM:SSZ)"
  positive_integer "$stale_after" || die "stale-after must be a positive integer"
  positive_integer "$progress_timeout" || die "progress-timeout must be a positive integer"
  [ "${#progress[@]}" -gt 0 ] || die "--progress needs an argv command"
  cwd=$(cd -P -- "$cwd" 2>/dev/null && pwd -P) || die "progress working directory is unavailable: $cwd"
  resolved=$(resolve_executable "${progress[0]}" "$cwd") \
    || die "progress executable is unavailable or not executable: ${progress[0]}"
  progress[0]=$resolved
  for arg in "${progress[@]}"; do
    safe_arg "$arg" || die "progress arguments must be printable and at most 4096 characters each"
  done

  load_runtime_libs
  fm_pid_alive "$pid" || die "cannot adopt pid $pid: process is not alive"
  process_is_zombie "$pid"
  zombie_rc=$?
  [ "$zombie_rc" -ne 0 ] || die "cannot adopt pid $pid: process is a zombie"
  [ "$zombie_rc" -ne 2 ] || die "cannot adopt pid $pid: process state is unknown"
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) \
    || die "cannot adopt pid $pid: process identity is unknown"
  safe_text "$current_identity" 131072 || die "cannot adopt pid $pid: process identity is not a single printable line"

  (umask 077; mkdir -p "$REGISTRY") || die "cannot create background-work registry: $REGISTRY"
  fm_lock_acquire_wait "$REGISTRY/.registry.lock"
  record="$REGISTRY/$id"
  if [ -e "$record" ] || [ -L "$record" ]; then
    fm_lock_release "$REGISTRY/.registry.lock"
    die "background work is already registered: $id"
  fi
  stage=$(umask 077; mktemp -d "$REGISTRY/.register.$id.XXXXXX") || {
    fm_lock_release "$REGISTRY/.registry.lock"
    die "cannot stage background-work record"
  }
  tmp="$stage/meta"
  if ! {
    printf 'schema=fm-background-work.v1\n'
    printf 'id=%s\n' "$id"
    printf 'description=%s\n' "$description"
    printf 'task=%s\n' "$task"
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$current_identity"
    printf 'started_at=%s\n' "$started_at"
    printf 'expected_finish_at=%s\n' "$expected_finish_at"
    printf 'cwd=%s\n' "$cwd"
    printf 'stale_after=%s\n' "$stale_after"
    printf 'progress_timeout=%s\n' "$progress_timeout"
  } > "$tmp" || ! chmod 600 "$tmp"; then
    rm -rf -- "$stage"
    fm_lock_release "$REGISTRY/.registry.lock"
    die "cannot write background-work metadata"
  fi
  tmp="$stage/progress.argv"
  if ! printf '%s\n' "${progress[@]}" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -rf -- "$stage"
    fm_lock_release "$REGISTRY/.registry.lock"
    die "cannot write background-work progress argv"
  fi
  if ! mv -- "$stage" "$record"; then
    rm -rf -- "$stage"
    fm_lock_release "$REGISTRY/.registry.lock"
    die "cannot publish background-work record"
  fi
  fm_lock_release "$REGISTRY/.registry.lock"
  printf 'registered: %s pid=%s\n' "$id" "$pid"
}

load_record() { # <record-directory>
  local dir=$1 meta="$1/meta"
  RECORD_VALID=0
  RECORD_ID=${dir##*/}
  RECORD_DESCRIPTION=''
  RECORD_TASK=''
  RECORD_PID=''
  RECORD_PID_IDENTITY=''
  RECORD_STARTED_AT=''
  RECORD_EXPECTED_FINISH_AT=''
  RECORD_CWD=''
  RECORD_STALE_AFTER=''
  RECORD_PROGRESS_TIMEOUT=''
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  RECORD_SCHEMA=$(meta_value "$meta" schema) || return 1
  [ "$RECORD_SCHEMA" = fm-background-work.v1 ] || return 1
  RECORD_META_ID=$(meta_value "$meta" id) || return 1
  [ "$RECORD_META_ID" = "$RECORD_ID" ] || return 1
  RECORD_DESCRIPTION=$(meta_value "$meta" description) || return 1
  RECORD_TASK=$(meta_value "$meta" task) || return 1
  RECORD_PID=$(meta_value "$meta" pid) || return 1
  RECORD_PID_IDENTITY=$(meta_value "$meta" pid_identity) || return 1
  RECORD_STARTED_AT=$(meta_value "$meta" started_at) || return 1
  RECORD_EXPECTED_FINISH_AT=$(meta_value "$meta" expected_finish_at) || return 1
  RECORD_CWD=$(meta_value "$meta" cwd) || return 1
  RECORD_STALE_AFTER=$(meta_value "$meta" stale_after) || return 1
  RECORD_PROGRESS_TIMEOUT=$(meta_value "$meta" progress_timeout) || return 1
  valid_id "$RECORD_ID" || return 1
  safe_text "$RECORD_DESCRIPTION" 240 || return 1
  safe_text "$RECORD_TASK" 160 || return 1
  case "$RECORD_PID" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$RECORD_PID_IDENTITY" ] || return 1
  valid_time "$RECORD_STARTED_AT" || return 1
  [ -z "$RECORD_EXPECTED_FINISH_AT" ] || valid_time "$RECORD_EXPECTED_FINISH_AT" || return 1
  positive_integer "$RECORD_STALE_AFTER" || return 1
  positive_integer "$RECORD_PROGRESS_TIMEOUT" || return 1
  RECORD_VALID=1
}

observe_liveness() {
  local current zombie_rc
  LIVENESS_STATUS=unknown
  LIVENESS_REASON='record-invalid'
  [ "$RECORD_VALID" -eq 1 ] || return 0
  if ! fm_pid_alive "$RECORD_PID"; then
    LIVENESS_STATUS=dead
    LIVENESS_REASON=process-missing
    return 0
  fi
  process_is_zombie "$RECORD_PID"
  zombie_rc=$?
  if [ "$zombie_rc" -eq 0 ]; then
    LIVENESS_STATUS=dead
    LIVENESS_REASON=zombie
    return 0
  fi
  if [ "$zombie_rc" -eq 2 ]; then
    LIVENESS_STATUS=unknown
    LIVENESS_REASON='process-state-unreadable'
    return 0
  fi
  current=$(fm_pid_identity "$RECORD_PID" 2>/dev/null) || {
    LIVENESS_STATUS=unknown
    LIVENESS_REASON='identity-unreadable'
    return 0
  }
  if [ "$current" != "$RECORD_PID_IDENTITY" ]; then
    LIVENESS_STATUS=dead
    LIVENESS_REASON='pid-reused'
    return 0
  fi
  LIVENESS_STATUS=alive
  LIVENESS_REASON='identity-match'
}

observation_write() { # <dir> <value> <changed-epoch> <changed-at> <observed-at>
  local dir=$1 value=$2 epoch=$3 changed_at=$4 observed_at=$5 tmp
  tmp=$(umask 077; mktemp "$dir/.observation.XXXXXX") || return 1
  if ! {
    printf 'value=%s\n' "$value"
    printf 'last_changed_epoch=%s\n' "$epoch"
    printf 'last_changed_at=%s\n' "$changed_at"
    printf 'last_observed_at=%s\n' "$observed_at"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$dir/observation"; then
    rm -f -- "$tmp"
    return 1
  fi
}

observe_progress() { # <record-directory> <now-epoch> <now-iso>
  local dir=$1 now=$2 now_iso=$3 argv_file="$1/progress.argv" output rc size bad_bytes arg
  local previous_value='' previous_epoch='' previous_changed_at='' age newline_count last_byte
  local lock="$1/.observe.lock"
  local -a argv=()
  PROGRESS_STATUS=unknown
  PROGRESS_REASON='record-invalid'
  PROGRESS_VALUE=''
  PROGRESS_OBSERVED_AT=''
  PROGRESS_LAST_CHANGED_AT=''
  [ "$RECORD_VALID" -eq 1 ] || return 0
  if [ "$LIVENESS_STATUS" != alive ]; then
    PROGRESS_REASON="process-$LIVENESS_STATUS"
    return 0
  fi
  [ -d "$RECORD_CWD" ] || { PROGRESS_REASON=working-directory-missing; return 0; }
  [ -f "$argv_file" ] && [ ! -L "$argv_file" ] \
    || { PROGRESS_REASON='progress-command-unreadable'; return 0; }
  while IFS= read -r arg || [ -n "$arg" ]; do
    argv+=("$arg")
  done < "$argv_file" || { PROGRESS_REASON='progress-command-unreadable'; return 0; }
  [ "${#argv[@]}" -gt 0 ] && [ -x "${argv[0]}" ] \
    || { PROGRESS_REASON='progress-command-unavailable'; return 0; }
  if ! fm_lock_try_acquire "$lock"; then
    PROGRESS_REASON=observation-busy
    return 0
  fi
  output=$(umask 077; mktemp "$dir/.progress-output.XXXXXX") || {
    fm_lock_release "$lock"
    PROGRESS_REASON=observation-unavailable
    return 0
  }
  (
    cd -P -- "$RECORD_CWD" || exit 125
    fm_run_timed "$RECORD_PROGRESS_TIMEOUT" "${argv[@]}" </dev/null 2>/dev/null
  ) | head -c $((MAX_PROGRESS_BYTES + 1)) > "$output"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 124 ]; then
    PROGRESS_REASON=timeout
  elif [ "$rc" -ne 0 ]; then
    PROGRESS_REASON=command-failed
  else
    size=$(wc -c < "$output" | tr -d '[:space:]')
    bad_bytes=$(LC_ALL=C tr -d '\n\40-\176' < "$output" | wc -c | tr -d '[:space:]')
    newline_count=$(tr -cd '\n' < "$output" | wc -c | tr -d '[:space:]')
    last_byte=$(tail -c 1 "$output" | od -An -tu1 | tr -d '[:space:]')
    if [ "$size" -eq 0 ]; then
      PROGRESS_REASON=empty-output
    elif [ "$size" -gt "$MAX_PROGRESS_BYTES" ]; then
      PROGRESS_REASON='output-too-long'
    elif [ "$bad_bytes" -ne 0 ] || [ "$newline_count" -gt 1 ] \
      || { [ "$newline_count" -eq 1 ] && [ "$last_byte" != 10 ]; }; then
      PROGRESS_REASON=invalid-output
    else
      PROGRESS_VALUE=$(sed -n '1p' "$output")
      if [ -z "$PROGRESS_VALUE" ]; then
        PROGRESS_REASON=empty-output
      else
        PROGRESS_OBSERVED_AT=$now_iso
        if [ -f "$dir/observation" ] && [ ! -L "$dir/observation" ]; then
          previous_value=$(meta_value "$dir/observation" value 2>/dev/null || true)
          previous_epoch=$(meta_value "$dir/observation" last_changed_epoch 2>/dev/null || true)
          previous_changed_at=$(meta_value "$dir/observation" last_changed_at 2>/dev/null || true)
        fi
        case "$previous_epoch" in ''|*[!0-9]*) previous_epoch='' ;; esac
        if [ -z "$previous_epoch" ]; then
          PROGRESS_STATUS=unknown
          PROGRESS_REASON='first-observation'
          previous_epoch=$now
          previous_changed_at=$now_iso
        elif [ "$PROGRESS_VALUE" != "$previous_value" ]; then
          PROGRESS_STATUS=progressing
          PROGRESS_REASON='value-changed'
          previous_epoch=$now
          previous_changed_at=$now_iso
        else
          age=$((now - previous_epoch))
          if [ "$age" -ge "$RECORD_STALE_AFTER" ]; then
            PROGRESS_STATUS=stalled
            PROGRESS_REASON='value-unchanged'
          else
            PROGRESS_STATUS=progressing
            PROGRESS_REASON=recent-change
          fi
        fi
        PROGRESS_LAST_CHANGED_AT=$previous_changed_at
        if ! observation_write "$dir" "$PROGRESS_VALUE" "$previous_epoch" \
          "$previous_changed_at" "$now_iso"; then
          PROGRESS_STATUS=unknown
          PROGRESS_REASON=observation-write-failed
        fi
      fi
    fi
  fi
  rm -f -- "$output"
  fm_lock_release "$lock"
}

record_json() { # <record-directory> <now-epoch> <now-iso> [budget-only]
  local dir=$1 now=$2 now_iso=$3 mode=${4-} pid_json=null expected_json=null value_json=null
  local observed_json=null changed_json=null description_json=null task_json=null started_json=null
  local stale_json=null timeout_json=null
  load_record "$dir" || true
  if [ "${BACKGROUND_COLLECTION_CONTEXT:-0}" = 1 ] \
    && [ "$RECORD_VALID" -eq 1 ] \
    && [ "$RECORD_PROGRESS_TIMEOUT" -gt "$COLLECTION_PROBE_TIMEOUT" ]; then
    RECORD_PROGRESS_TIMEOUT=$COLLECTION_PROBE_TIMEOUT
  fi
  if [ "$mode" = budget-only ]; then
    LIVENESS_STATUS=unknown
    LIVENESS_REASON=collection-budget
    PROGRESS_STATUS=unknown
    PROGRESS_REASON=collection-budget
    PROGRESS_VALUE=''
    PROGRESS_OBSERVED_AT=''
    PROGRESS_LAST_CHANGED_AT=''
  else
    observe_liveness
    observe_progress "$dir" "$now" "$now_iso"
  fi
  if [ "$RECORD_VALID" -eq 1 ]; then
    pid_json=$RECORD_PID
    description_json=$(jq -Rn --arg value "$RECORD_DESCRIPTION" '$value')
    task_json=$(jq -Rn --arg value "$RECORD_TASK" '$value')
    started_json=$(jq -Rn --arg value "$RECORD_STARTED_AT" '$value')
    stale_json=$RECORD_STALE_AFTER
    timeout_json=$RECORD_PROGRESS_TIMEOUT
    [ -z "$RECORD_EXPECTED_FINISH_AT" ] \
      || expected_json=$(jq -Rn --arg value "$RECORD_EXPECTED_FINISH_AT" '$value')
  fi
  [ -z "$PROGRESS_VALUE" ] || value_json=$(jq -Rn --arg value "$PROGRESS_VALUE" '$value')
  [ -z "$PROGRESS_OBSERVED_AT" ] \
    || observed_json=$(jq -Rn --arg value "$PROGRESS_OBSERVED_AT" '$value')
  [ -z "$PROGRESS_LAST_CHANGED_AT" ] \
    || changed_json=$(jq -Rn --arg value "$PROGRESS_LAST_CHANGED_AT" '$value')
  jq -n -c \
    --arg id "$RECORD_ID" \
    --argjson description "$description_json" \
    --argjson task "$task_json" \
    --argjson pid "$pid_json" \
    --argjson started_at "$started_json" \
    --argjson expected_finish_at "$expected_json" \
    --arg liveness_status "$LIVENESS_STATUS" \
    --arg liveness_reason "$LIVENESS_REASON" \
    --arg progress_status "$PROGRESS_STATUS" \
    --arg progress_reason "$PROGRESS_REASON" \
    --argjson progress_value "$value_json" \
    --argjson observed_at "$observed_json" \
    --argjson last_changed_at "$changed_json" \
    --argjson stale_after_seconds "$stale_json" \
    --argjson timeout_seconds "$timeout_json" \
    '{id:$id, description:$description, task:$task, pid:$pid,
      started_at:$started_at, expected_finish_at:$expected_finish_at,
      liveness:{status:$liveness_status, reason:$liveness_reason},
      progress:{status:$progress_status, reason:$progress_reason,
        value:$progress_value, observed_at:$observed_at,
        last_changed_at:$last_changed_at,
        stale_after_seconds:$stale_after_seconds,
        timeout_seconds:$timeout_seconds}}'
}

collect_records() { # <output-directory> <now-epoch> <now-iso>
  local output=$1 now=$2 generated=$3 record id tmp count=0 worker watchdog monitor_was_on=0
  local -a workers=()
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  for record in "$REGISTRY"/*; do
    [ -d "$record" ] && [ ! -L "$record" ] || continue
    count=$((count + 1))
    [ "$count" -le "$COLLECTION_MAX_PROBES" ] || continue
    id=${record##*/}
    tmp="$output/.${id}.$$"
    (BACKGROUND_COLLECTION_CONTEXT=1 record_json "$record" "$now" "$generated" > "$tmp" \
      && mv -f -- "$tmp" "$output/$id.json" \
      && : > "$output/$id.complete") &
    workers+=("$!")
  done
  (
    sleep "$COLLECTION_BUDGET"
    for worker in "${workers[@]+"${workers[@]}"}"; do
      kill -TERM -- "-$worker" 2>/dev/null || true
    done
    sleep 0.2
    for worker in "${workers[@]+"${workers[@]}"}"; do
      kill -KILL -- "-$worker" 2>/dev/null || true
    done
  ) &
  watchdog=$!
  [ "$monitor_was_on" -eq 1 ] || set +m
  for worker in "${workers[@]+"${workers[@]}"}"; do
    wait "$worker" 2>/dev/null || true
  done
  kill -TERM -- "-$watchdog" 2>/dev/null || kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

list_work() {
  local format=${1-} generated now records_tmp record document stage id total=0 attempted=0 completed=0 truncated=false
  case "$format" in ''|--json) ;; *) die "unknown list option: $format" ;; esac
  command -v jq >/dev/null 2>&1 || die "jq is required to list background work"
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "cannot read the current UTC time"
  now=$(date +%s) || die "cannot read the current epoch time"
  records_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-background-work-list.XXXXXX") \
    || die "cannot stage background-work output"
  : > "$records_tmp"
  if [ -d "$REGISTRY" ]; then
    load_runtime_libs
    stage=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-background-work-collect.XXXXXX") \
      || { rm -f -- "$records_tmp"; die "cannot stage background-work collection"; }
    for record in "$REGISTRY"/*; do
      [ -d "$record" ] && [ ! -L "$record" ] || continue
      total=$((total + 1))
      [ "$attempted" -ge "$COLLECTION_MAX_PROBES" ] || attempted=$((attempted + 1))
      id=${record##*/}
      record_json "$record" "$now" "$generated" budget-only > "$stage/$id.json" \
        || { rm -rf -- "$stage"; rm -f -- "$records_tmp"; die "cannot encode background-work record: $id"; }
    done
    collect_records "$stage" "$now" "$generated"
    for record in "$REGISTRY"/*; do
      [ -d "$record" ] && [ ! -L "$record" ] || continue
      id=${record##*/}
      [ ! -f "$stage/$id.complete" ] || completed=$((completed + 1))
      cat "$stage/$id.json" >> "$records_tmp" \
        || { rm -rf -- "$stage"; rm -f -- "$records_tmp"; die "cannot read background-work result: $id"; }
    done
    rm -rf -- "$stage"
  fi
  [ "$completed" -eq "$attempted" ] && [ "$attempted" -eq "$total" ] || truncated=true
  document=$(jq -s --arg generated "$generated" --arg home "$FM_HOME" \
    --argjson budget "$COLLECTION_BUDGET" --argjson total "$total" \
    --argjson attempted "$attempted" --argjson completed "$completed" --argjson truncated "$truncated" \
    '{schema:"fm-background-work-list.v1", generated:$generated, fm_home:$home,
      collection:{budget_seconds:$budget,total_records:$total,probes_attempted:$attempted,
        probes_completed:$completed,truncated:$truncated},records:.}' \
    "$records_tmp") || { rm -f -- "$records_tmp"; die "cannot encode background-work list"; }
  rm -f -- "$records_tmp"
  if [ "$format" = --json ]; then
    printf '%s\n' "$document"
  else
    printf 'ID\tTASK\tLIVENESS\tPROGRESS\tVALUE\tSTARTED\tEXPECTED\tDESCRIPTION\n'
    printf '%s\n' "$document" | jq -r '.records[] | [
      .id, (.task // "-"), .liveness.status, .progress.status,
      (.progress.value // "-"), (.started_at // "-"),
      (.expected_finish_at // "-"), (.description // "-")
    ] | @tsv'
  fi
}

retire_work() {
  local id=${1-} record entry observe_owner
  valid_id "$id" || die "invalid background-work id: $id"
  [ -d "$REGISTRY" ] || { printf 'absent: %s\n' "$id"; return 0; }
  load_runtime_libs
  fm_lock_acquire_wait "$REGISTRY/.registry.lock"
  record="$REGISTRY/$id"
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    fm_lock_release "$REGISTRY/.registry.lock"
    printf 'absent: %s\n' "$id"
    return 0
  fi
  [ -d "$record" ] && [ ! -L "$record" ] || {
    fm_lock_release "$REGISTRY/.registry.lock"
    die "background-work record is not a private directory: $id"
  }
  if ! fm_lock_try_acquire "$record/.observe.lock"; then
    fm_lock_release "$REGISTRY/.registry.lock"
    die "background-work record is being observed: $id"
  fi
  observe_owner=${FM_LOCK_OWNER_DIR:-}
  for entry in "$record"/* "$record"/.[!.]* "$record"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$entry" = "$record/.observe.lock" ] && continue
    [ -n "$observe_owner" ] && [ "$entry" = "$observe_owner" ] && continue
    case "${entry##*/}" in
      meta|progress.argv|observation) ;;
      *)
        fm_lock_release "$record/.observe.lock"
        fm_lock_release "$REGISTRY/.registry.lock"
        die "background-work record contains an unexpected path: $entry"
        ;;
    esac
  done
  rm -f -- "$record/meta" "$record/progress.argv" "$record/observation" \
    || { fm_lock_release "$record/.observe.lock"; fm_lock_release "$REGISTRY/.registry.lock"; die "cannot remove background-work record files: $id"; }
  fm_lock_release "$record/.observe.lock"
  rmdir -- "$record" \
    || { fm_lock_release "$REGISTRY/.registry.lock"; die "cannot retire background-work record: $id"; }
  fm_lock_release "$REGISTRY/.registry.lock"
  printf 'retired: %s (process was not signalled)\n' "$id"
}

case "${1-}" in
  register) shift; register_work "$@" ;;
  list) shift; [ "$#" -le 1 ] || { usage >&2; exit 2; }; list_work "${1-}" ;;
  retire) shift; [ "$#" -eq 1 ] || { usage >&2; exit 2; }; retire_work "$1" ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
