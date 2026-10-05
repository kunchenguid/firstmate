#!/usr/bin/env bash
# fm-tasks-axi.sh - task CRUD entrypoint for the per-task record owner.
#
# Canonical task data lives only in data/<task>/task.json.  This wrapper keeps
# established callers on one command surface while bin/fm-task-record.py owns
# create/read/update/list/filter behavior. Retained legacy task files are inert
# and never read or mutated by ordinary queries. Explicit one-time migration:
#   backfill-archived --state-dir <state> --preview > manifest.json
#   backfill-archived --state-dir <state> --apply-file manifest.json
# Missing known ordinary identities become archived; existing files stay unchanged.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CALLER_DIR=$(pwd)

usage() {
  sed -n '2,13s/^# *//p' "$0"
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
exec python3 "$SCRIPT_DIR/fm-task-record.py" --data "$DATA" "${ARGS[@]}"
