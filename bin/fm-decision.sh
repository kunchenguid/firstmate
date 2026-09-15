#!/usr/bin/env bash
# bin/fm-decision.sh — CLI for recording and inspecting structured decisions in state/<id>.decisions.jsonl
# Usage:
#   fm-decision.sh log <task-id> --choice "<choice>" --rationale "<rationale>" \
#                                [--rejected-opt "<option>:<reason>"]... \
#                                [--constraint "<constraint>"]... \
#                                [--outcome "<outcome>"] [--key "<key>"]
#   fm-decision.sh list <task-id>
#   fm-decision.sh show <task-id> <key>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-decision-lib.sh
. "$SCRIPT_DIR/fm-decision-lib.sh"

usage() {
  echo "usage: fm-decision.sh log <task-id> --choice \"<choice>\" --rationale \"<rationale>\" [options]"
  echo "       fm-decision.sh list <task-id>"
  echo "       fm-decision.sh show <task-id> <key>"
  echo ""
  echo "options for log:"
  echo "  --choice \"...\"             The selected approach or architectural choice (required)"
  echo "  --rationale \"...\"          Reason for this choice (required)"
  echo "  --rejected-opt \"opt:reason\" Rejected alternative and reason (can be passed multiple times)"
  echo "  --rejected-json \"[...]\"    JSON array of rejected options objects"
  echo "  --constraint \"...\"         Discovered constraint or boundary (can be passed multiple times)"
  echo "  --constraints-json \"[...]\" JSON array of constraint strings"
  echo "  --outcome \"...\"            Observed or expected outcome"
  echo "  --key \"...\"                Decision key/slug (auto-generated if omitted)"
}

if [ $# -lt 2 ]; then
  usage >&2
  exit 1
fi

ACTION="$1"
TASK_ID="$2"
shift 2

case "$ACTION" in
  log)
    CHOICE=""
    RATIONALE=""
    OUTCOME=""
    KEY=""
    REJECTED_JSON=""
    CONSTRAINTS_JSON=""
    declare -a REJECTED_OPTS=()
    declare -a CONSTRAINTS=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --choice)
          CHOICE="$2"
          shift 2 ;;
        --rationale)
          RATIONALE="$2"
          shift 2 ;;
        --outcome)
          OUTCOME="$2"
          shift 2 ;;
        --key)
          KEY="$2"
          shift 2 ;;
        --rejected-opt)
          REJECTED_OPTS+=("$2")
          shift 2 ;;
        --rejected-json)
          REJECTED_JSON="$2"
          shift 2 ;;
        --constraint)
          CONSTRAINTS+=("$2")
          shift 2 ;;
        --constraints-json)
          CONSTRAINTS_JSON="$2"
          shift 2 ;;
        -h|--help)
          usage; exit 0 ;;
        *)
          echo "fm-decision: unknown argument '$1'" >&2
          exit 1 ;;
      esac
    done

    if [ -z "$CHOICE" ] || [ -z "$RATIONALE" ]; then
      echo "error: --choice and --rationale are required" >&2
      exit 1
    fi

    if [ -z "$REJECTED_JSON" ]; then
      if [ ${#REJECTED_OPTS[@]} -gt 0 ]; then
        # Build JSON array of rejected options
        REJECTED_JSON=$(python3 -c '
import sys, json
opts = sys.argv[1:]
arr = []
for o in opts:
    if ":" in o:
        name, reason = o.split(":", 1)
        arr.append({"option": name.strip(), "reason": reason.strip()})
    else:
        arr.append({"option": o.strip(), "reason": "Alternative rejected"})
print(json.dumps(arr))
' "${REJECTED_OPTS[@]}")
      else
        REJECTED_JSON="[]"
      fi
    fi

    if [ -z "$CONSTRAINTS_JSON" ]; then
      if [ ${#CONSTRAINTS[@]} -gt 0 ]; then
        CONSTRAINTS_JSON=$(python3 -c '
import sys, json
print(json.dumps(sys.argv[1:]))
' "${CONSTRAINTS[@]}")
      else
        CONSTRAINTS_JSON="[]"
      fi
    fi

    fm_decision_log "$STATE_DIR" "$TASK_ID" "$CHOICE" "$RATIONALE" "$REJECTED_JSON" "$CONSTRAINTS_JSON" "$OUTCOME" "$KEY"
    echo "Decision logged for $TASK_ID (${KEY:-auto})"
    ;;

  list)
    fm_decision_list "$STATE_DIR" "$TASK_ID"
    ;;

  show)
    if [ $# -lt 1 ]; then
      echo "error: decision key required for show" >&2
      exit 1
    fi
    KEY="$1"
    fm_decision_get "$STATE_DIR" "$TASK_ID" "$KEY"
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac
