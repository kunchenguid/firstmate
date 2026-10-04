#!/usr/bin/env bash
# fm-tasks-axi.sh - task CRUD entrypoint for the per-task record owner.
#
# Canonical task data lives only in data/<task>/task.json.  This wrapper keeps
# established callers on one command surface while bin/fm-task-record.py owns
# create/read/update/list/filter behavior. Retained legacy task files are inert
# and never read or mutated here. The established
# `public-followup` typed-obligation family is not task storage; it remains an
# explicit passthrough to its existing tasks-axi owner.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CALLER_DIR=$(pwd)

usage() {
  sed -n '2,9s/^# *//p' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ -d "$DATA" ] || { printf 'fm-tasks-axi: data directory cannot be resolved: %s\n' "$DATA" >&2; exit 2; }

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    case "$arg" in /*) ARGS+=("$arg") ;; *) ARGS+=("$CALLER_DIR/$arg") ;; esac
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      echo 'fm-tasks-axi: --file is unsupported; per-task records are addressed by FM_HOME' >&2
      exit 2
      ;;
    --to|--*-file)
      ARGS+=("$arg"); path_value_next=1
      ;;
    --to=*|--*-file=*)
      value=${arg#*=}
      case "$value" in /*) ;; *) value="$CALLER_DIR/$value" ;; esac
      ARGS+=("${arg%%=*}=$value")
      ;;
    *) ARGS+=("$arg") ;;
  esac
done

[ "${#ARGS[@]}" -gt 0 ] || ARGS=(list)
if [ "${ARGS[0]}" = public-followup ]; then
  # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  command -v tasks-axi >/dev/null 2>&1 || {
    echo 'fm-tasks-axi: tasks-axi is required for the public-followup compatibility family' >&2
    exit 2
  }
  FM_BACKLOG_TRANSITION_ERROR=
  fm_backlog_tasks_axi_addressing "$DATA" || {
    printf 'fm-tasks-axi: %s\n' "${FM_BACKLOG_TRANSITION_ERROR:-cannot resolve typed-obligation backend}" >&2
    exit 2
  }
  if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
    [ ! -L "$FM_BACKLOG_AXI_FILE" ] || {
      printf 'fm-tasks-axi: typed-obligation file is a symlink: %s\n' "$FM_BACKLOG_AXI_FILE" >&2
      exit 2
    }
    export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
  else
    unset TASKS_AXI_FILE
  fi
  cd "$FM_BACKLOG_AXI_ROOT" || exit 2
  exec tasks-axi "${ARGS[@]}"
fi
exec python3 "$SCRIPT_DIR/fm-task-record.py" --data "$DATA" "${ARGS[@]}"
