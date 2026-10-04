# shellcheck shell=bash
# Read-only task-record dispositions shared by fleet and wake projections.
#
# Canonical per-task records are the only task-disposition source.
# Missing records remain unknown and never inherit data from retained backlog or archive files.
#
# Output from fm_task_disposition_snapshot is sorted TSV:
#   <task-id>\t<active|queued|done|archive_done|parked>

FM_TASK_DISPOSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_task_disposition_snapshot() {  # <data-dir>
  local data=$1
  while [ "$data" != / ] && [ "${data%/}" != "$data" ]; do data=${data%/}; done
  python3 "$FM_TASK_DISPOSITION_LIB_DIR/fm-task-record.py" --data "$data" inventory | jq -r '    .tasks[] | [.id,
      (if .state == "in_flight" then "active"
       elif .state == "queued" and .hold.kind == "parked" then "parked"
       elif .state == "queued" then "queued"
       elif .state == "done" then "done"
       else "archive_done" end)] | @tsv' | LC_ALL=C sort
}
fm_task_disposition_for() {  # <snapshot-tsv> <task-id>
  local snapshot=$1 task=$2 id disposition
  while IFS=$(printf '\t') read -r id disposition; do
    [ "$id" = "$task" ] || continue
    printf '%s\n' "$disposition"
    return 0
  done <<EOF
$snapshot
EOF
  return 1
}

# Refuse terminal work and fail closed when the canonical business record is absent.
fm_task_disposition_effect_guard() { # <data-dir> <task-id> [operation]
  local data=$1 task=$2 operation=${3:-effect} disposition detail_error detail_rc
  [ -d "$data" ] || {
    printf 'REFUSED: task %s has no canonical task data; %s cannot assume it is nonterminal\n' "$task" "$operation" >&2
    return 6
  }
  # shellcheck source=bin/fm-task-progress-lib.sh
  . "$FM_TASK_DISPOSITION_LIB_DIR/fm-task-progress-lib.sh"
  detail_error=$(mktemp "${TMPDIR:-/tmp}/fm-task-disposition.XXXXXX") || return 1
  if fm_task_progress_detail "$task" 2>"$detail_error"; then
    :
  else
    detail_rc=$?
    if grep -qx 'code: NOT_FOUND' "$detail_error"; then
      printf 'REFUSED: task %s has no canonical task record; %s cannot assume it is nonterminal\n' "$task" "$operation" >&2
      detail_rc=6
    else
      cat "$detail_error" >&2
    fi
    rm -f "$detail_error"
    return "$detail_rc"
  fi
  rm -f "$detail_error"
  case "$FM_TASK_PROGRESS_STATE" in
    "done") disposition="done" ;;
    archived) disposition=archive_done ;;
    *) return 0 ;;
  esac
  printf 'REFUSED: task %s is explicitly terminal (%s); %s cannot start new work\n' \
    "$task" "$disposition" "$operation" >&2
  return 6
}

# A retired remote id must not be reused when old private history proves that
# it already owned an execution. This is a read-only immutable identity fact,
# not active lifecycle admission or progress.
fm_task_historical_execution_guard() { # <data-dir> <task-id>
  local data=$1 task=$2 record="$1/$2/lifecycle.json" current_status
  # shellcheck source=bin/fm-remote-execution-receipt-lib.sh
  . "$FM_TASK_DISPOSITION_LIB_DIR/fm-remote-execution-receipt-lib.sh"
  fm_remote_execution_receipt_guard "$data" "$task" || return $?
  # A retained rich record cannot govern a reused id while the configured
  # ordinary task owner still has a current row. The dedicated execution
  # receipt above remains authoritative regardless of row presence.
  if fm_task_progress_current_absent "$task"; then
    current_status=0
  else
    current_status=$?
  fi
  [ "$current_status" -ne 2 ] || return 6
  [ "$current_status" -eq 0 ] || return 0
  [ -e "$record" ] || [ -L "$record" ] || return 0
  [ -f "$record" ] && [ ! -L "$record" ] || {
    echo "REFUSED: task $task has unsafe retained execution history" >&2
    return 6
  }
  if jq -e --arg task "$task" '
      (.schema == "fm-task-lifecycle.v1" or .schema == "fm-task-lifecycle.v2") and
      .task_id == $task and (.execution_generation | type == "string") and
      .execution_generation != "unassigned-g1"
    ' "$record" >/dev/null 2>&1; then
    echo "REFUSED: task $task already has a retained execution identity; use a separately authorized new task" >&2
    return 6
  fi
  jq -e --arg task "$task" '
    (.schema == "fm-task-lifecycle.v1" or .schema == "fm-task-lifecycle.v2") and .task_id == $task
  ' "$record" >/dev/null 2>&1 || {
    echo "REFUSED: task $task retained execution history is unreadable or mismatched" >&2
    return 6
  }
}
