#!/usr/bin/env bash
# fm-telemetry-lib.sh - best-effort private lifecycle telemetry.
#
# Usage: source this file, then call fm_telemetry_record <stream> <json-object>
# or fm_telemetry_record_wait <task> <attempt> <owner> <key> <open|resumed>.
# Streams are lifecycle, checks, and liveness. Lifecycle rows receive the
# additive task, attempt, operation, and home identity envelope. Rows are
# compact JSONL under data/telemetry, mode 0600; failed recording never changes
# the caller result.
set -u

FM_TELEMETRY_MAX_BYTES=${FM_TELEMETRY_MAX_BYTES:-52428800}
case "$FM_TELEMETRY_MAX_BYTES" in ''|*[!0-9]*|0) FM_TELEMETRY_MAX_BYTES=52428800 ;; esac
FM_TELEMETRY_SEQUENCE=${FM_TELEMETRY_SEQUENCE:-0}
case "$FM_TELEMETRY_SEQUENCE" in ''|*[!0-9]*) FM_TELEMETRY_SEQUENCE=0 ;; esac

fm_telemetry_warn() {
  printf 'warning: telemetry %s\n' "$1" >&2
}

fm_telemetry_data_dir() {
  local data=${FM_DATA_OVERRIDE:-${FM_HOME:-${FM_ROOT:-.}}/data}
  printf '%s/telemetry\n' "${data%/}"
}

fm_telemetry_stream_valid() {
  case "$1" in lifecycle|checks|liveness) return 0 ;; esac
  return 1
}

fm_telemetry_home_id() {
  local home=${FM_HOME:-${FM_ROOT:-.}} id
  id=${FM_TELEMETRY_HOME_ID:-${home##*/}}
  case "$id" in
    ''|*[!A-Za-z0-9._:-]*) printf 'unknown' ;;
    *) printf '%s' "$id" ;;
  esac
}

fm_telemetry_now_ms() {
  case "${FM_TELEMETRY_NOW_MS:-}" in
    ''|*[!0-9]*) : ;;
    *) printf '%s\n' "$FM_TELEMETRY_NOW_MS"; return 0 ;;
  esac
  if declare -F fm_timing_now_ms >/dev/null 2>&1; then
    fm_timing_now_ms
  else
    date +%s000 2>/dev/null || printf '0\n'
  fi
}

fm_telemetry_task_attempt() { # <task-id>
  local task=${1:-} home=${FM_HOME:-${FM_ROOT:-.}} state meta
  state=${FM_STATE_OVERRIDE:-${STATE:-$home/state}}
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  meta="$state/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  awk -F= '$1=="telemetry_attempt" { value=substr($0,index($0,"=")+1) } END { print value }' "$meta" 2>/dev/null
}

fm_telemetry_record() { # <stream> <json-object>
  local stream=${1:-} payload=${2:-} dir file ts home row rc lock acquired size row_bytes
  local task attempt operation
  fm_telemetry_stream_valid "$stream" || { fm_telemetry_warn 'invalid stream'; return 0; }
  dir=$(fm_telemetry_data_dir)
  file="$dir/$stream.jsonl"
  ts=$(fm_telemetry_now_ms) || { fm_telemetry_warn 'clock unavailable'; return 0; }
  home=$(fm_telemetry_home_id)
  task=${FM_TELEMETRY_TASK_ID:-${ID:-}}
  case "$task" in ''|*[!A-Za-z0-9._-]*) task= ;; esac
  attempt=${FM_TELEMETRY_ATTEMPT_ID:-${TELEMETRY_ATTEMPT:-}}
  [ -n "$attempt" ] || attempt=$(fm_telemetry_task_attempt "$task")
  FM_TELEMETRY_SEQUENCE=$((FM_TELEMETRY_SEQUENCE + 1))
  operation=${FM_TELEMETRY_OPERATION_ID:-fmo-${ts}-${BASHPID:-$$}-${FM_TELEMETRY_SEQUENCE}}
  if ! row=$(printf '%s' "$payload" | jq -ce --argjson ts "$ts" --arg home "$home" \
    --arg task "$task" --arg attempt "$attempt" --arg operation "$operation" --arg stream "$stream" '
      select(type=="object") | .ts=$ts | .home=$home
      | if $stream=="lifecycle" then
          .homeId=$home
          | .taskId=(.taskId // (if $task=="" then null else $task end))
          | .attemptId=(.attemptId // (if $attempt=="" then null else $attempt end))
          | .operationId=(.operationId // $operation)
          | if ((.status | type)=="number" and .status!=0 and (has("refusalCode")|not))
            then .refusalCode=("exit-"+(.status|tostring)) else . end
        else . end'); then
    fm_telemetry_warn 'payload is not a JSON object'
    return 0
  fi
  if [ ! -d "$dir" ] && [ -e "$dir" ] || [ -L "$dir" ]; then
    fm_telemetry_warn 'directory is not safe'
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null || [ -L "$dir" ]; then
    fm_telemetry_warn 'directory is unavailable'
    return 0
  fi
  for path in "$file" "$file.1" "$file.2"; do
    [ ! -L "$path" ] || { fm_telemetry_warn 'stream path is symlinked'; return 0; }
    [ ! -e "$path" ] || [ -f "$path" ] || { fm_telemetry_warn 'stream path is not a file'; return 0; }
  done
  lock="$file.lock"
  acquired=0
  if mkdir "$lock" 2>/dev/null; then
    chmod 0700 "$lock" 2>/dev/null || true
    acquired=1
  fi
  if [ "$acquired" -ne 1 ]; then
    fm_telemetry_warn 'append lock unavailable'
    return 0
  fi
  size=0
  [ ! -e "$file" ] || size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  row_bytes=$(printf '%s\n' "$row" | wc -c | tr -d '[:space:]')
  if [ "$size" -gt 0 ] && [ "$((size + row_bytes))" -gt "$FM_TELEMETRY_MAX_BYTES" ]; then
    rm -f -- "$file.2" 2>/dev/null || true
    [ ! -e "$file.1" ] || mv -f -- "$file.1" "$file.2" || acquired=0
    [ "$acquired" -eq 1 ] && mv -f -- "$file" "$file.1" || acquired=0
  fi
  if [ "$acquired" -eq 1 ]; then
    if ! printf '%s\n' "$row" >> "$file" 2>/dev/null || ! chmod 0600 "$file" 2>/dev/null; then
      acquired=0
    fi
  fi
  rmdir "$lock" 2>/dev/null || true
  if [ "$acquired" -eq 1 ]; then return 0; fi
  rc=1
  fm_telemetry_warn "append failed (rc=$rc)"
  return 0
}

fm_telemetry_lifecycle_files() {
  local file candidate
  file="$(fm_telemetry_data_dir)/lifecycle.jsonl"
  for candidate in "$file.2" "$file.1" "$file"; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && printf '%s\n' "$candidate"
  done
}

fm_telemetry_open_wait_owner() { # <task> <attempt> <key>
  local task=$1 attempt=$2 key=$3 file lifecycle_files=()
  while IFS= read -r file; do lifecycle_files+=("$file"); done < <(fm_telemetry_lifecycle_files)
  [ "${#lifecycle_files[@]}" -gt 0 ] || return 0
  jq -sjr --arg task "$task" --arg attempt "$attempt" --arg key "$key" '
    [.[] | select(.op=="wait" and .taskId==$task and ((.attemptId // "")==$attempt)
      and .waitKey==$key and (.openedAt|type)=="number" and .resumedAt==null)]
    | if length==0 then empty else last.waitOwner end' "${lifecycle_files[@]}" 2>/dev/null
}

fm_telemetry_record_wait() { # <task> <attempt> <main|secondmate|lock|provider|captain> <key> <open|resumed>
  local task=${1:-} attempt=${2:-} owner=${3:-} key=${4:-} transition=${5:-}
  local now opened=null file row lifecycle_files=()
  case "$task" in ''|*[!A-Za-z0-9._-]*) fm_telemetry_warn 'wait task is invalid'; return 0 ;; esac
  case "$owner" in main|secondmate|lock|provider|captain) ;; *) fm_telemetry_warn 'wait owner is invalid'; return 0 ;; esac
  [ -n "$key" ] || { fm_telemetry_warn 'wait key is empty'; return 0; }
  now=$(fm_telemetry_now_ms) || { fm_telemetry_warn 'clock unavailable'; return 0; }
  case "$transition" in
    open) opened=$now ;;
    resumed)
      while IFS= read -r file; do lifecycle_files+=("$file"); done < <(fm_telemetry_lifecycle_files)
      if [ "${#lifecycle_files[@]}" -gt 0 ]; then
        opened=$(jq -sr --arg task "$task" --arg attempt "$attempt" --arg owner "$owner" --arg key "$key" '
          [.[] | select(.op=="wait" and .taskId==$task
            and ((.attemptId // "")==$attempt) and .waitOwner==$owner and .waitKey==$key
            and (.openedAt|type)=="number" and .resumedAt==null)]
          | if length==0 then null else last.openedAt end' "${lifecycle_files[@]}" 2>/dev/null) || opened=null
      fi
      ;;
    *) fm_telemetry_warn 'wait transition is invalid'; return 0 ;;
  esac
  row=$(jq -cn --arg task "$task" --arg attempt "$attempt" --arg owner "$owner" --arg key "$key" \
    --argjson opened "$opened" --argjson resumed "$(if [ "$transition" = resumed ]; then printf '%s' "$now"; else printf null; fi)" '
      {op:"wait",taskId:$task,attemptId:(if $attempt=="" then null else $attempt end),
       waitOwner:$owner,waitKey:$key,openedAt:$opened,resumedAt:$resumed}') || return 0
  fm_telemetry_record lifecycle "$row"
}

fm_telemetry_record_status_line() { # <state> <status-file> <status-line>
  local state=$1 file=$2 line=$3 task attempt verb key note owner transition
  task=${file##*/}
  task=${task%.status}
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  declare -F status_line_verb >/dev/null 2>&1 || return 0
  verb=$(status_line_verb "$line")
  key=$(_fm_decision_key "$line" 2>/dev/null) || return 0
  note=$(status_line_note "$line" 2>/dev/null || true)
  attempt=$(FM_STATE_OVERRIDE="$state" fm_telemetry_task_attempt "$task")
  case "$verb" in
    blocked)
      owner=main
      case "$key" in
        pending-reply-*) owner=secondmate ;;
        quota-exhausted) owner=provider ;;
      esac
      transition=open
      ;;
    needs-decision|captain-held)
      owner=captain
      transition=open
      ;;
    resolved)
      owner=$(fm_telemetry_open_wait_owner "$task" "$attempt" "$key")
      [ -n "$owner" ] || owner=captain
      transition=resumed
      ;;
    working)
      case "$note" in *resumed*|*Resumed*) ;; *) return 0 ;; esac
      owner=$(fm_telemetry_open_wait_owner "$task" "$attempt" "$key")
      [ -n "$owner" ] || owner=main
      transition=resumed
      ;;
    *) return 0 ;;
  esac
  fm_telemetry_record_wait "$task" "$attempt" "$owner" "$key" "$transition"
}
