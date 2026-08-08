#!/usr/bin/env bash
# GitHub Copilot CLI hook transport for Firstmate's shared lifecycle scripts.
#
# Usage:
#   fm-copilot-hook.sh session-start
#   fm-copilot-hook.sh agent-stop
#   fm-copilot-hook.sh pre-arm
#   fm-copilot-hook.sh pre-cd
#   fm-copilot-hook.sh pre-subagent
#
# Copilot's repository hooks use camelCase events and JSON decision objects.
# This adapter translates those payloads into the existing harness-neutral
# script interfaces. Every malformed or unavailable transport path stays inert
# except a shared policy script's explicit denial, which preserves its exit 2.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}

json_field() {  # <payload> <python expression>
  local payload=$1 expression=$2
  command -v python3 >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); v=$expression; print(v if isinstance(v, str) else json.dumps(v))" \
    2>/dev/null
}

json_object() {  # <field> <value>
  local field=$1 value=$2
  command -v python3 >/dev/null 2>&1 || return 1
  FIELD="$field" VALUE="$value" python3 -c \
    'import json,os; print(json.dumps({os.environ["FIELD"]: os.environ["VALUE"]}, separators=(",", ":")))'
}

case "$MODE" in
  session-start)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    DIGEST=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh" 2>/dev/null || true)
    [ -n "$DIGEST" ] || exit 0
    json_object additionalContext "$DIGEST" || exit 0
    ;;
  agent-stop)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    STOP_ACTIVE=$(json_field "$PAYLOAD" 'd.get("stop_hook_active", False)') || exit 0
    SESSION_ID=$(json_field "$PAYLOAD" 'd.get("sessionId", d.get("session_id", "unknown"))') || exit 0
    case "$STOP_ACTIVE" in
      true|false) ;;
      *) exit 0 ;;
    esac
    REASON_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-stop.XXXXXX") || exit 0
    trap 'rm -f "$REASON_FILE"' EXIT HUP INT TERM
    if "$SCRIPT_DIR/fm-turnend-guard.sh" \
      --stop-active "$STOP_ACTIVE" --session-id "$SESSION_ID" \
      </dev/null 2>"$REASON_FILE"; then
      exit 0
    else
      STATUS=$?
    fi
    [ "$STATUS" -eq 2 ] || exit 0
    REASON=$(cat "$REASON_FILE" 2>/dev/null || true)
    [ -n "$REASON" ] || exit 0
    command -v python3 >/dev/null 2>&1 || exit 0
    REASON="$REASON" python3 -c \
      'import json,os; print(json.dumps({"decision":"block","reason":os.environ["REASON"]}, separators=(",", ":")))'
    ;;
  pre-arm|pre-cd)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    COMMAND=$(json_field "$PAYLOAD" 'd.get("toolArgs", {}).get("command", "")') || exit 0
    [ -n "$COMMAND" ] || exit 0
    if [ "$MODE" = pre-arm ]; then
      exec "$SCRIPT_DIR/fm-arm-pretool-check.sh" --command "$COMMAND" --claude
    fi
    exec "$SCRIPT_DIR/fm-cd-pretool-check.sh" --command "$COMMAND" --claude
    ;;
  pre-subagent)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    TOOL=$(json_field "$PAYLOAD" 'd.get("toolName", "")') || exit 0
    [ -n "$TOOL" ] || exit 0
    exec "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --tool "$TOOL" --claude
    ;;
  *)
    echo "usage: $(basename "$0") session-start|agent-stop|pre-arm|pre-cd|pre-subagent" >&2
    exit 2
    ;;
esac
