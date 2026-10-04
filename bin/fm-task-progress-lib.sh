# shellcheck shell=bash
# MAIN-owned goal continuation over the canonical data/<task>/task.json record.
# Reads and updates are record-local.  Aggregated discovery scans all records in
# one process and persists no index or snapshot.

FM_TASK_PROGRESS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_task_progress_file() { # <task>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*) echo "REFUSED: invalid task id: $1" >&2; return 2 ;;
  esac
  printf '%s/%s/task.json' "${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" "$1"
}

fm_task_progress_detail() { # <task>; sets task business and progress globals
  local record
  record=$(FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" \
    "$FM_TASK_PROGRESS_BIN/fm-tasks-axi.sh" progress "$1") || return $?
  FM_TASK_PROGRESS_RECORD=$record
  FM_TASK_PROGRESS_GOAL=$(printf '%s' "$record" | jq -er '.title') || return 1
  FM_TASK_PROGRESS_STATE=$(printf '%s' "$record" | jq -er '.state') || return 1
  FM_TASK_PROGRESS_HELD=$(printf '%s' "$record" | jq -r 'if .hold == null then "no" else "yes" end') || return 1
  FM_TASK_PROGRESS_BLOCKED=$(printf '%s' "$record" | jq -r 'if (.blocked_by|length) == 0 then "no" else "yes" end') || return 1
  FM_TASK_PROGRESS_BODY=$(printf '%s' "$record" | jq -r '.body') || return 1
  FM_TASK_PROGRESS_LINKS=$(printf '%s' "$record" | jq -r '.links | to_entries | map(.key+":"+.value) | join(",")') || return 1
}

fm_task_progress_read() ( # <task>
  FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" \
    "$FM_TASK_PROGRESS_BIN/fm-tasks-axi.sh" progress-view "$1"
)

fm_task_progress_values() ( # <task>
  fm_task_progress_detail "$1" || return $?
  printf '%s' "$FM_TASK_PROGRESS_RECORD" | jq -c '.progress'
)

fm_task_progress_update() ( # <task> <progress-json>
  local id=$1 progress=$2 record
  [ "${FM_SUPERVISION_ACTOR:-main}" = main ] || {
    echo 'REFUSED: task progress belongs to MAIN' >&2
    exit 6
  }
  record=$(FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" \
    "$FM_TASK_PROGRESS_BIN/fm-tasks-axi.sh" update-progress-view "$id" --progress "$progress") || exit $?
  # The record owner returns its validated in-memory value after atomic publish;
  # no write-after-read confirmation or provider/backend query follows.
  printf '%s\n' "$record"
)

fm_task_progress_list() ( # canonical in-flight records
  local data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}
  python3 "$FM_TASK_PROGRESS_BIN/fm-task-record.py" --data "$data" progress-list
)

fm_task_progress_current_absent() { # <task>
  local file
  file=$(fm_task_progress_file "$1") || return 2
  [ ! -e "$file" ] && [ ! -L "$file" ] && return 0
  [ -f "$file" ] && [ ! -L "$file" ] && return 1
  echo "REFUSED: task record is not a regular file: $file" >&2
  return 2
}

fm_task_progress_completion_guard() ( # <task>
  local projection file
  file=$(fm_task_progress_file "$1") || return $?
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    echo "REFUSED: task $1 has no canonical task record" >&2
    return 6
  fi
  projection=$(fm_task_progress_read "$1") || return $?
  # A captain hold is a disposition constraint, not a business-goal gap. The
  # teardown owner independently verifies its inventory and retains the task
  # row instead of closing the captain's call.
  printf '%s' "$projection" | jq -e '
    .recorded == true and .task_state == "in_flight" and
    .task_blocked == "no" and
    (.task_held == "no" or .task_hold_kind == "captain") and
    .remaining_gap == "" and .next_step == ""' >/dev/null || {
    echo "REFUSED: task $1 is not MAIN-accepted; clear its current remaining gap or explicitly archive it before cleanup" >&2
    return 6
  }
)
