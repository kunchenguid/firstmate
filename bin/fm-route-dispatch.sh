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

AUTO_CHARTER=0
REGISTRY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --task) [ $# -ge 2 ] || { echo "error: --task requires a value" >&2; exit 2; }; TASK=$2; shift 2 ;;
    --brief) [ $# -ge 2 ] || { echo "error: --brief requires a value" >&2; exit 2; }; BRIEF=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || { echo "error: --registry requires a value" >&2; exit 2; }; REGISTRY=$2; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --auto-charter) AUTO_CHARTER=1; shift ;;
    --json) AS_JSON=1; shift ;;
    -h|--help)
      echo "Usage: fm-route-dispatch.sh [--task <text>] [--brief <file>] [--registry <file>] [--execute] [--auto-charter] [--json]"
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
EXTRA_ARGS=()
if [ "$AUTO_CHARTER" -eq 1 ]; then
  EXTRA_ARGS+=(--auto-charter)
fi
if [ -n "$REGISTRY" ]; then
  EXTRA_ARGS+=(--registry "$REGISTRY")
fi
ROUTER_JSON=$(python3 "$SCRIPT_DIR/fm-route-domain.py" --json --task "$TASK_INPUT" "${EXTRA_ARGS[@]}")

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "$ROUTER_JSON"
  exit 0
fi

ACTION=$(echo "$ROUTER_JSON" | jq -r '.action')
ROUTE=$(echo "$ROUTER_JSON" | jq -r '.route')
CONF=$(echo "$ROUTER_JSON" | jq -r '.confidence // 0')
NOUL=$(echo "$ROUTER_JSON" | jq -r '.needs_new_noul // 0')
WALLED=$(echo "$ROUTER_JSON" | jq -r '.seat_wall.walled // false')
OVERRIDE_FLAGS=$(echo "$ROUTER_JSON" | jq -r '.seat_wall.override_flags // ""')
CHARTERED=$(echo "$ROUTER_JSON" | jq -r '.auto_charter.chartered // false')
CHARTERED_DOMAIN=$(echo "$ROUTER_JSON" | jq -r '.auto_charter.domain // ""')
CHARTERED_HOME=$(echo "$ROUTER_JSON" | jq -r '.auto_charter.home // ""')

printf '=== Jev Front-Door Router ===\n'
printf 'Action:     %s\n' "$ACTION"
printf 'Route:      %s\n' "$ROUTE"
printf 'Confidence: %s\n' "$CONF"
printf 'New Domain: %s\n' "$NOUL"
if [ "$WALLED" = "true" ]; then
  printf 'Seat Wall:  YES (Claude exhausted; suggested override: %s)\n' "$OVERRIDE_FLAGS"
fi
printf '=============================\n'

case "$ACTION" in
  handle_direct)
    printf 'Status: Direct communication for Captain / First Mate. Not dispatched.\n'
    ;;
  create_secondmate)
    if [ "$CHARTERED" = "true" ]; then
      printf 'Status: Auto-chartered new Second Mate "%s".\n' "$CHARTERED_DOMAIN"
      printf 'Home scaffolded: %s\n' "$CHARTERED_HOME"
      printf 'Ready to spawn:  bin/fm-spawn.sh %s --secondmate\n' "$CHARTERED_DOMAIN"
    else
      printf 'Status: Unmatched domain (%s). Firstmate should charter a new Second Mate.\n' "$ROUTE"
      printf 'Suggested workflow:\n'
      printf '  1. Define domain charter in data/secondmates.md\n'
      printf '  2. Run: bin/fm-spawn.sh <new-id> --secondmate\n'
      printf '  3. Dispatch task to new secondmate inbox.\n'
      printf '  (Pass --auto-charter to charter and scaffold automatically)\n'
    fi
    ;;
  dispatch)
    CLEAN_TASK=$(printf '%s' "$TASK_INPUT" | tr '\n' ' ' | head -c 300)
    SEND_ARGS=""
    if [ "$WALLED" = "true" ] && [ -n "$OVERRIDE_FLAGS" ]; then
      SEND_ARGS=" $OVERRIDE_FLAGS"
    fi
    SEND_CMD="FM_HOME=$FM_HOME \"$SCRIPT_DIR/fm-send.sh\" \"$ROUTE\"$SEND_ARGS \"[fm-from-firstmate] $CLEAN_TASK\""
    if [ "$EXECUTE" -eq 1 ]; then
      printf 'Executing dispatch to second mate: %s ...\n' "$ROUTE"
      # shellcheck disable=SC2086
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ROUTE"$SEND_ARGS "[fm-from-firstmate] $CLEAN_TASK"
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
