#!/usr/bin/env bash
# fm-route-dispatch.sh - Jev front-door router & dispatcher for incoming tasks.
#
# Usage:
#   fm-route-dispatch.sh --task "<description>" [--execute] [--json]
#   fm-route-dispatch.sh --brief <file> [--execute] [--json]
#
# If --execute is specified, it automatically dispatches matched tasks to the
# owning second mate using bin/fm-send.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TASK=""
BRIEF=""
EXECUTE=0
AS_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --task) [ $# -ge 2 ] || { echo "error: --task requires a value" >&2; exit 2; }; TASK=$2; shift 2 ;;
    --brief) [ $# -ge 2 ] || { echo "error: --brief requires a value" >&2; exit 2; }; BRIEF=$2; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --json) AS_JSON=1; shift ;;
    -h|--help)
      echo "Usage: fm-route-dispatch.sh [--task <text>] [--brief <file>] [--execute] [--json]"
      exit 0
      ;;
    *)
      if [ -z "$TASK" ]; then
        TASK=$1
        shift
      else
        echo "error: unexpected argument $1" >&2
        exit 2
      fi
      ;;
  esac
done

if [ -n "$BRIEF" ] && [ -f "$BRIEF" ]; then
  TASK_INPUT=$(cat "$BRIEF")
elif [ -n "$TASK" ]; then
  TASK_INPUT="$TASK"
else
  echo "error: either --task or --brief is required" >&2
  exit 2
fi

# Run Jev domain classifier
ROUTER_JSON=$(python3 "$SCRIPT_DIR/fm-route-domain.py" --json --task "$TASK_INPUT")

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "$ROUTER_JSON"
  exit 0
fi

ACTION=$(echo "$ROUTER_JSON" | jq -r '.action')
ROUTE=$(echo "$ROUTER_JSON" | jq -r '.route')
CONF=$(echo "$ROUTER_JSON" | jq -r '.confidence // 0')
NOUL=$(echo "$ROUTER_JSON" | jq -r '.needs_new_noul // 0')

printf '=== Jev Front-Door Router ===\n'
printf 'Action:     %s\n' "$ACTION"
printf 'Route:      %s\n' "$ROUTE"
printf 'Confidence: %s\n' "$CONF"
printf 'New Domain: %s\n' "$NOUL"
printf '=============================\n'

case "$ACTION" in
  handle_direct)
    printf 'Status: Direct communication for Captain / First Mate. Not dispatched.\n'
    ;;
  create_secondmate)
    printf 'Status: Unmatched domain (%s). Firstmate should charter a new Second Mate.\n' "$ROUTE"
    printf 'Suggested workflow:\n'
    printf '  1. Define domain charter in data/secondmates.md\n'
    printf '  2. Run: bin/fm-spawn.sh <new-id> --secondmate\n'
    printf '  3. Dispatch task to new secondmate inbox.\n'
    ;;
  dispatch)
    CLEAN_TASK=$(printf '%s' "$TASK_INPUT" | tr '\n' ' ' | head -c 300)
    SEND_CMD="FM_HOME=$FM_HOME \"$SCRIPT_DIR/fm-send.sh\" \"$ROUTE\" \"[fm-from-firstmate] $CLEAN_TASK\""
    if [ "$EXECUTE" -eq 1 ]; then
      printf 'Executing dispatch to second mate: %s ...\n' "$ROUTE"
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ROUTE" "[fm-from-firstmate] $CLEAN_TASK"
      printf 'Dispatched successfully to %s.\n' "$ROUTE"
    else
      printf 'Recommended dispatch command:\n  %s\n' "$SEND_CMD"
      printf 'Pass --execute to dispatch automatically.\n'
    fi
    ;;
  unavailable)
    REASON=$(echo "$ROUTER_JSON" | jq -r '.reason // "unknown"')
    printf 'Status: Router unavailable (%s). Falling back to Firstmate direct handling.\n' "$REASON"
    ;;
  *)
    printf 'Status: Unknown router action: %s\n' "$ACTION"
    ;;
esac
