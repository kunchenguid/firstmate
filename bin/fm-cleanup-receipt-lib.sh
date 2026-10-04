# shellcheck shell=bash
# Existing cleanup operation receipt. This is executor-generation and effect
# readback only; it never records task goals, progress, acceptance, or archive.

FM_CLEANUP_RECEIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_cleanup_receipt() { # <operation> <task> <generation> [extra args]
  local operation=$1 task=$2 generation=$3 state
  shift 3
  state=${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:?}/state}}
  FM_HOME="${FM_HOME:?}" FM_STATE_OVERRIDE="$state" \
    python3 "$FM_CLEANUP_RECEIPT_DIR/fm-cleanup-receipt.py" "$operation" "$task" \
      --generation "$generation" "$@"
}

fm_cleanup_historical_merge_receipt() { # <task> <generation>; emits exact facts or refuses ambiguity
  local id=$1 generation=$2 path
  path="${FM_DATA_OVERRIDE:-${DATA:-${FM_HOME:?}/data}}/$id/lifecycle.json"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  jq -ce --arg id "$id" --arg generation "$generation" '
    select((.schema == "fm-task-lifecycle.v1" or .schema == "fm-task-lifecycle.v2") and
      .task_id == $id and .execution_generation == $generation) |
    [.owner_receipts.merge[]? | select(.execution_generation == $generation) | .facts] |
    if length == 1 and (.[0].url | type == "string" and length > 0) and
      (.[0].head | type == "string" and length > 0) then .[0] else empty end
  ' "$path"
}

fm_cleanup_completion_mode() ( # <task> <generation>; emits accepted|archived
  local id=$1 projection progress_error progress_status=0
  # shellcheck source=bin/fm-task-progress-lib.sh
  . "$FM_CLEANUP_RECEIPT_DIR/fm-task-progress-lib.sh"
  progress_error=$(mktemp "${TMPDIR:-/tmp}/fm-cleanup-progress.XXXXXX") || return 1
  trap 'rm -f "$progress_error"' EXIT
  if projection=$(fm_task_progress_read "$id" 2>"$progress_error"); then
    # A current canonical task record always outranks any retained
    # rich-lifecycle file from an older scope.
    if [ "$(printf '%s' "$projection" | jq -r '.task_state')" = archived ]; then
      printf 'archived\n'; return 0
    fi
    if printf '%s' "$projection" | jq -e '
      .recorded == true and
      ((.task_state == "in_flight" and .task_held == "no" and .task_blocked == "no") or
       .task_state == "done") and
      .remaining_gap == "" and .next_step == ""' >/dev/null; then
      printf 'accepted\n'; return 0
    fi
    echo "REFUSED: compact task $id is not MAIN-accepted; clear its current remaining gap or explicitly archive it before cleanup" >&2
    return 6
  else
    progress_status=$?
  fi
  grep -qx 'code: NOT_FOUND' "$progress_error" || {
    if [ -s "$progress_error" ]; then
      cat "$progress_error" >&2
    else
      echo "REFUSED: task $id cannot be torn down because its current original-task progress could not be read" >&2
    fi
    return "$progress_status"
  }
  echo "REFUSED: task $id has no canonical task record; cleanup cannot infer acceptance or archive state" >&2
  return 6
)

fm_cleanup_completion_guard() { # <task> <generation>
  fm_cleanup_completion_mode "$1" "$2" >/dev/null
}

fm_cleanup_delivery_guard() { # <task> <generation> <meta>
  local id=$1 generation=$2 meta=$3 kind url head report completion
  completion=$(fm_cleanup_completion_mode "$id" "$generation") || return $?
  [ "$completion" != archived ] || return 0
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    scout)
      report="${FM_DATA_OVERRIDE:-${DATA:-${FM_HOME:?}/data}}/$id/report.md"
      [ -f "$report" ] && [ ! -L "$report" ] || {
        echo "REFUSED: accepted scout $id has no final report" >&2; return 1;
      }
      "$FM_CLEANUP_RECEIPT_DIR/fm-captain-hold.sh" verify "$id" >/dev/null || return 1
      ;;
    ship)
      # shellcheck source=bin/fm-merge-receipt-lib.sh
      . "$FM_CLEANUP_RECEIPT_DIR/fm-merge-receipt-lib.sh"
      url=$(sed -n 's/^pr=//p' "$meta" | tail -1)
      head=$(sed -n 's/^pr_head=//p' "$meta" | tail -1)
      fm_merge_receipt_current "$id" "$generation" "$url" "$head" >/dev/null || return 1
      ;;
    *) echo "REFUSED: unsupported completed task kind: $kind" >&2; return 1 ;;
  esac
}
