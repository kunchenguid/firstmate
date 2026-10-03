#!/usr/bin/env bash
# fm-tasks-axi.sh - compatibility entrypoint for the per-task record owner.
#
# Canonical task data lives only in data/<task>/task.json.  This wrapper keeps
# established callers on one command surface while bin/fm-task-record.py owns
# create/read/update/list/filter behavior.  Legacy backlog files are never
# mutated here and remain available only to the explicit import path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CALLER_DIR=$(pwd)

usage() {
  sed -n '2,8s/^# *//p' "$0"
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
    --body-file)
      ARGS+=("$arg"); path_value_next=1
      ;;
    --body-file=*)
      value=${arg#*=}
      case "$value" in /*) ;; *) value="$CALLER_DIR/$value" ;; esac
      ARGS+=("--body-file=$value")
      ;;
    *) ARGS+=("$arg") ;;
  esac
done

[ "${#ARGS[@]}" -gt 0 ] || ARGS=(list)
exec python3 "$SCRIPT_DIR/fm-task-record.py" --data "$DATA" "${ARGS[@]}"
