# shellcheck shell=bash
# Read-only task-record dispositions shared by fleet and wake projections.
#
# Canonical per-task records are authoritative when present. This legacy
# projection reads retained markdown backlog/archive evidence only for homes
# that have not explicitly imported those rows yet. A unique checked archive
# row can prove terminal disposition; duplicate rows remain ambiguous and
# visible. A queued row with `hold-kind: parked` is parked, not executing.
#
# Output from fm_task_disposition_snapshot is sorted TSV:
#   <task-id>\t<active|queued|done|archive_done|parked|ambiguous>
#
# Unsupported backends and inaccessible archives never infer completion: the
# function returns an empty/smaller set so readers preserve unknown work rather
# than hiding it.

FM_TASK_DISPOSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$FM_TASK_DISPOSITION_LIB_DIR/fm-tasks-axi-lib.sh"

fm_task_disposition_snapshot() {  # <data-dir> [required-archive-artifact]
  local data=$1 root backlog archive archive_input=/dev/null backend canonical legacy
  while [ "$data" != / ] && [ "${data%/}" != "$data" ]; do data=${data%/}; done
  canonical=$(python3 "$FM_TASK_DISPOSITION_LIB_DIR/fm-task-record.py" --data "$data" inventory \
    | jq -r '.tasks[] | [.id,
        (if .state == "in_flight" then "active"
         elif .state == "queued" and .hold.kind == "parked" then "parked"
         elif .state == "queued" then "queued"
         elif .state == "done" then "done"
         else "archive_done" end)] | @tsv') || return 1
  case "$data" in
    */*) root=${data%/*}; [ -n "$root" ] || root=/ ;;
    *) root=. ;;
  esac
  # A different or unreadable legacy backend contributes no fallback rows;
  # canonical records remain readable and authoritative.
  backend=$(fm_tasks_axi_backend_resolve "$root" 2>/dev/null) || {
    printf '%s\n' "$canonical" | sed '/^$/d' | LC_ALL=C sort
    return 0
  }
  if [ "$backend" != markdown ]; then
    printf '%s\n' "$canonical" | sed '/^$/d' | LC_ALL=C sort
    return 0
  fi
  backlog="${data%/}/backlog.md"
  archive=$(fm_tasks_axi_markdown_archive_resolve "$root" "$data" 2>/dev/null) || archive=
  if [ -n "$archive" ] && [ -f "$archive" ] && [ -r "$archive" ] && [ ! -L "$archive" ]; then
    archive_input=$archive
  fi
  if [ -e "$backlog" ] || [ -L "$backlog" ]; then
    [ -f "$backlog" ] && [ -r "$backlog" ] && [ ! -L "$backlog" ] || return 1
  else
    backlog=/dev/null
  fi

  legacy=$(LC_ALL=C awk -v backlog="$backlog" -v archive="$archive_input" -v artifact="${2:-}" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function artifact_present(value, position, before, after) {
      if (artifact == "") return 1
      position=index(value, artifact)
      if (!position) return 0
      before=position > 1 ? substr(value, position-1, 1) : ""
      after=substr(value, position+length(artifact), 1)
      return before !~ /[[:alnum:]_./?&=%#~@+-]/ && after !~ /[[:alnum:]_./?&=%#~@+:-]/
    }
    function task_id(line, value) {
      value=line
      if (value ~ /^[-*][[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+/) {
        sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", value)
        sub(/[[:space:]]+-[[:space:]].*$/, "", value)
        return trim(value)
      }
      if (value ~ /^[-*][[:space:]]+\*\*[^*]+\*\*[[:space:]]+-[[:space:]]+/) {
        sub(/^[-*][[:space:]]+\*\*/, "", value)
        sub(/\*\*[[:space:]]+-[[:space:]].*$/, "", value)
        return trim(value)
      }
      return ""
    }
    FILENAME == backlog {
      if ($0 ~ /^##[[:space:]]+/) {
        heading=$0
        sub(/^##[[:space:]]+/, "", heading)
        heading=trim(heading)
        if (heading == "In flight") section="in_flight"
        else if (heading == "Queued") section="queued"
        else if (heading == "Done") section="done"
        else section=""
        next
      }
      id=task_id($0)
      if (section == "" || id == "") next
      current_count[id]++
      if (section == "done") current_value[id]="done"
      else if (section == "queued" && $0 ~ /[(,][[:space:]]*hold-kind:[[:space:]]*parked([[:space:]]*[,)]|[[:space:]]*$)/) current_value[id]="parked"
      else if (section == "queued") current_value[id]="queued"
      else current_value[id]="active"
      next
    }
    FILENAME == archive {
      if ($0 ~ /^##[[:space:]]+/) {
        archived_section=($0 ~ /^##[[:space:]]+Archived[[:space:]]+/)
        archived_id=""
        next
      }
      id=task_id($0)
      if (id != "") {
        archived_id=""
        if (archived_section) {
          archived[id]++
          if ($0 ~ /^[-*][[:space:]]+\[[xX]\]/) {
            archive_checked[id]=1
            archived_id=id
            archive_artifact[id]=artifact_present($0)
          }
        }
      } else if (archived_id != "" && $0 ~ /^[[:space:]]+/) {
        archive_artifact[archived_id]=archive_artifact[archived_id] || artifact_present($0)
      }
    }
    END {
      for (id in current_count) {
        if (current_count[id] != 1) print id "\tambiguous"
        else print id "\t" current_value[id]
      }
      for (id in archived) {
        if (!(id in current_count)) {
          if (archived[id] != 1) print id "\tambiguous"
          else if (archive_checked[id] && archive_artifact[id]) print id "\tarchive_done"
        }
      }
    }
  ' "$backlog" "$archive_input") || return 1
  # Legacy evidence fills only identities that have no canonical record.
  printf '%s\n%s\n' "$legacy" "$canonical" | sed '/^$/d' \
    | LC_ALL=C awk -F '\t' '{ disposition[$1]=$2 } END { for (id in disposition) print id "\t" disposition[id] }' \
    | LC_ALL=C sort
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

# Refuse only a positively identified business-terminal task. Unknown legacy
# records remain operable, while a current Done row or unique checked archive
# can never gain a new steer, handoff, worker or provider effect merely because
# its endpoint/resource record was retained for cleanup.
fm_task_disposition_effect_guard() { # <data-dir> <task-id> [operation]
  local data=$1 task=$2 operation=${3:-effect} snapshot disposition detail_error detail_rc root backend
  # Historical/manual homes with no ordinary task source keep their established
  # operability; absence of a data directory is not evidence of terminality.
  [ -d "$data" ] || return 0
  # The canonical exact task-record read wins over the legacy markdown
  # projection. Business completion is an effect boundary even when retained
  # descriptive progress still names a gap; MAIN must explicitly reopen the
  # task before any retained resource can resume effects.
  # shellcheck source=bin/fm-task-progress-lib.sh
  . "$FM_TASK_DISPOSITION_LIB_DIR/fm-task-progress-lib.sh"
  detail_error=$(mktemp "${TMPDIR:-/tmp}/fm-task-disposition.XXXXXX") || return 1
  if fm_task_progress_detail "$task" 2>"$detail_error"; then
    rm -f "$detail_error"
    case "$FM_TASK_PROGRESS_STATE" in
      done) disposition="done" ;;
      archived) disposition="archive_done" ;;
      *) return 0 ;;
    esac
  else
    detail_rc=$?
    if ! grep -qx 'code: NOT_FOUND' "$detail_error"; then
      cat "$detail_error" >&2
      rm -f "$detail_error"
      return "$detail_rc"
    fi
    rm -f "$detail_error"
    snapshot=$(fm_task_disposition_snapshot "$data") || return 1
    disposition=$(fm_task_disposition_for "$snapshot" "$task" 2>/dev/null || true)
    if [ -z "$disposition" ]; then
      while [ "$data" != / ] && [ "${data%/}" != "$data" ]; do data=${data%/}; done
      case "$data" in
        */*) root=${data%/*}; [ -n "$root" ] || root=/ ;;
        *) root=. ;;
      esac
      backend=$(fm_tasks_axi_backend_resolve "$root") || return 1
      if [ "$backend" != markdown ]; then
        printf 'REFUSED: task %s is absent from the backend-neutral current-task read; %s cannot assume it is nonterminal\n' \
          "$task" "$operation" >&2
        return 6
      fi
    fi
  fi
  case "$disposition" in
    done|archive_done)
      printf 'REFUSED: task %s is explicitly terminal (%s); %s cannot start new work\n' \
        "$task" "$disposition" "$operation" >&2
      return 6
      ;;
  esac
  return 0
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
