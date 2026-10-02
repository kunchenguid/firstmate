#!/usr/bin/env bash
# fm-route-dispatch.sh - Jev front-door router & dispatcher for incoming tasks.
#
# Usage:
#   fm-route-dispatch.sh --task "<description>" [--execute] [--json]
#   fm-route-dispatch.sh --brief <file> [--execute] [--json]
#
# If --execute is specified, it automatically dispatches matched tasks to the
# owning second mate using bin/fm-send.sh. A dispatch message whose base64
# form exceeds MAX_ENCODED_BYTES is refused unsent (exit 2). With --json --execute, the
# router JSON is always printed, extended with `dispatched` and
# `send_exit_code`, and the script exits with the send status.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-$FM_ROOT}"

# A remote send base64-encodes the message into one ssh argument, and Linux
# caps a single argument at 131072 bytes (MAX_ARG_STRLEN). The rest is headroom
# for the marker, correlation, ids, and the entrypoint's other encoded words.
MAX_ENCODED_BYTES=120000
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

if [ -n "$BRIEF" ]; then
  [ -f "$BRIEF" ] || { echo "error: brief file not found: $BRIEF" >&2; exit 2; }
  ROUTER_ARGS=(--brief "$BRIEF")
elif [ -n "$TASK" ]; then
  ROUTER_ARGS=("--task=$TASK")
else
  echo "error: either --task or --brief is required" >&2
  exit 2
fi

# Run Jev domain classifier
ROUTER_JSON=$(python3 "$SCRIPT_DIR/fm-route-domain.py" --json "${ROUTER_ARGS[@]}")

# Prints one router field verbatim, then "x" so $(...) cannot strip the
# value's own trailing newlines. python3 is already the router's dependency.
router_field() {
  printf '%s' "$ROUTER_JSON" | python3 -c '
import json, sys
v = json.load(sys.stdin).get(sys.argv[1])
sys.stdout.write(sys.argv[2] if v is None else str(v))
sys.stdout.write("x")' "$1" "${2-}"
}
field() { local v; v=$(router_field "$@"); printf '%s' "${v%x}"; }

ACTION=$(field action)
ROUTE=$(field route)
CONF=$(field confidence 0)
NOUL=$(field needs_new_noul 0)
MESSAGE=$(router_field dispatch_message)
MESSAGE=${MESSAGE%x}
MESSAGE_BYTES=$(printf '%s' "$MESSAGE" | wc -c | tr -d ' ')
# shellcheck disable=SC2017 # ceil(bytes / 3) * 4 is the base64 length
ENCODED_BYTES=$(( (MESSAGE_BYTES + 2) / 3 * 4 ))

message_fits() {
  [ "$ENCODED_BYTES" -le "$MAX_ENCODED_BYTES" ] && return 0
  echo "error: dispatch message is $MESSAGE_BYTES bytes ($ENCODED_BYTES base64), over the $MAX_ENCODED_BYTES-byte encoded single-argument limit of the send transport; not sent" >&2
  return 1
}

if [ "$AS_JSON" -eq 1 ]; then
  if [ "$EXECUTE" -eq 1 ] && [ "$ACTION" = dispatch ]; then
    SEND_RC=0
    if message_fits; then
      "$SCRIPT_DIR/fm-send.sh" "$ROUTE" "$MESSAGE" >&2 || SEND_RC=$?
    else
      SEND_RC=2
    fi
    printf '%s' "$ROUTER_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rc = int(sys.argv[1])
d.update(dispatched=rc == 0, send_exit_code=rc)
print(json.dumps(d, indent=2))' "$SEND_RC"
    exit "$SEND_RC"
  fi
  printf '%s\n' "$ROUTER_JSON"
  exit 0
fi

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
    SEND_CMD=$(printf 'FM_HOME=%q %q %q %q' "$(cd "$FM_HOME" && pwd)" "$SCRIPT_DIR/fm-send.sh" "$ROUTE" "$MESSAGE")
    if [ "$EXECUTE" -eq 1 ]; then
      message_fits || exit 2
      printf 'Executing dispatch to second mate: %s ...\n' "$ROUTE"
      "$SCRIPT_DIR/fm-send.sh" "$ROUTE" "$MESSAGE"
      printf 'Dispatched successfully to %s.\n' "$ROUTE"
    else
      printf 'Recommended dispatch command:\n  %s\n' "$SEND_CMD"
      printf 'Pass --execute to dispatch automatically.\n'
    fi
    ;;
  unavailable)
    REASON=$(field reason unknown)
    printf 'Status: Router unavailable (%s). Falling back to Firstmate direct handling.\n' "$REASON"
    ;;
  *)
    printf 'Status: Unknown router action: %s\n' "$ACTION"
    ;;
esac
