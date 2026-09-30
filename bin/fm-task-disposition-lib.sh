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
