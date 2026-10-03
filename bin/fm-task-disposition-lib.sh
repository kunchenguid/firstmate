# shellcheck shell=bash
# Read-only task-record dispositions shared by fleet and wake projections.
#
# The active markdown backlog is authoritative when it contains an id. Only
# when no current row exists may tasks-axi's configured Done archive provide a
# terminal disposition, with a unique checked row and any requested exact
# artifact preserved on that row/body. Duplicate rows are ambiguous and deliberately
# remain visible. A queued row held with the structured `hold-kind: parked`
# metadata is an explicit parked disposition, not current execution.
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
  local data=$1 root backlog archive archive_input=/dev/null backend
  while [ "$data" != / ] && [ "${data%/}" != "$data" ]; do data=${data%/}; done
  case "$data" in
    */*) root=${data%/*}; [ -n "$root" ] || root=/ ;;
    *) root=. ;;
  esac
  # A different or unreadable backend means this markdown reader cannot prove
  # any disposition. Emit no guesses so callers keep those records unknown.
  backend=$(fm_tasks_axi_backend_resolve "$root" 2>/dev/null) || return 0
  [ "$backend" = markdown ] || return 0
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

  LC_ALL=C awk -v backlog="$backlog" -v archive="$archive_input" -v artifact="${2:-}" '
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
  ' "$backlog" "$archive_input" | LC_ALL=C sort
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
  local data=$1 task=$2 operation=${3:-effect} snapshot disposition detail_error detail_rc values root backend
  # Historical/manual homes with no ordinary task source keep their established
  # operability; absence of a data directory is not evidence of terminality.
  [ -d "$data" ] || return 0
  # The backend-neutral exact row read wins over the markdown projection. A
  # Done row whose sole compact record still has a gap remains unfinished and
  # may receive the authorized continuation needed to repair its disposition.
  # shellcheck source=bin/fm-task-progress-lib.sh
  . "$FM_TASK_DISPOSITION_LIB_DIR/fm-task-progress-lib.sh"
  detail_error=$(mktemp "${TMPDIR:-/tmp}/fm-task-disposition.XXXXXX") || return 1
  if fm_task_progress_detail "$task" 2>"$detail_error"; then
    rm -f "$detail_error"
    [ "$FM_TASK_PROGRESS_STATE" = "done" ] || return 0
    values=$(fm_task_progress_values "$task") || return $?
    if [ "$values" != null ] && printf '%s' "$values" | jq -e \
        '.remaining_gap != "" and .next_step != ""' >/dev/null; then
      return 0
    fi
    disposition="done"
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
      root=$(fm_backlog_root "$data") || return 1
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
