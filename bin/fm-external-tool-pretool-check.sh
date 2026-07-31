#!/usr/bin/env bash
# Stable harness transport for the machine-readable external-tool policy in a protected task brief.
#
# The brief is the only authorization source. This wrapper extracts native hook
# payload fields, invokes bin/fm-external-tool-command-policy.mjs, and renders
# the harness-specific deny shape. It never classifies command semantics.
#
# Usage:
#   <PreToolUse JSON on stdin> | fm-external-tool-pretool-check.sh --brief <path> [--format claude|grok|plain]
#   fm-external-tool-pretool-check.sh --brief <path> --tool <name> --input-json <json> [--format plain]
#   fm-external-tool-pretool-check.sh --brief <path> --command <command> [--format plain]
#   fm-external-tool-pretool-check.sh --brief <path> --validate
#
# Allow exits 0 silently. Deny exits 2. Invalid transport, unavailable policy
# runtime, and invalid or missing brief policy also exit 2 so a protected ship
# or promotable scout never loses enforcement after spawn validation.
set -u

BRIEF=
TOOL=
INPUT_JSON='{}'
COMMAND=
FORMAT=plain
VALIDATE=0
TOOL_SET=0
INPUT_SET=0
COMMAND_SET=0

usage() {
  sed -n '2,16{s/^# \{0,1\}//;p;}' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --brief) [ "$#" -gt 1 ] || { echo "error: --brief requires a value" >&2; exit 2; }; BRIEF=$2; shift 2 ;;
    --brief=*) BRIEF=${1#--brief=}; shift ;;
    --tool) [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }; TOOL=$2; TOOL_SET=1; shift 2 ;;
    --tool=*) TOOL=${1#--tool=}; TOOL_SET=1; shift ;;
    --input-json) [ "$#" -gt 1 ] || { echo "error: --input-json requires a value" >&2; exit 2; }; INPUT_JSON=$2; INPUT_SET=1; shift 2 ;;
    --input-json=*) INPUT_JSON=${1#--input-json=}; INPUT_SET=1; shift ;;
    --command) [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }; COMMAND=$2; COMMAND_SET=1; shift 2 ;;
    --command=*) COMMAND=${1#--command=}; COMMAND_SET=1; shift ;;
    --format) [ "$#" -gt 1 ] || { echo "error: --format requires a value" >&2; exit 2; }; FORMAT=$2; shift 2 ;;
    --format=*) FORMAT=${1#--format=}; shift ;;
    --validate) VALIDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$FORMAT" in claude|grok|plain) ;; *) echo "error: --format must be claude, grok, or plain" >&2; exit 2 ;; esac
[ -n "$BRIEF" ] || { echo "fm-external-tool-policy: --brief is required" >&2; exit 2; }

render_deny() {
  local detail=$1 escaped
  escaped=$(printf '%s' "$detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  case "$FORMAT" in
    claude)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
      ;;
    grok)
      printf '%s\n' "$detail" >&2
      printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
      ;;
    plain)
      printf '%s\n' "$detail" >&2
      ;;
  esac
  exit 2
}

if [ "$VALIDATE" -eq 0 ] && [ "$TOOL_SET" -eq 0 ] && [ "$INPUT_SET" -eq 0 ] && [ "$COMMAND_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || render_deny '[external-tool-policy-error] PreToolUse payload is empty; refusing an unclassified ship tool call'
  command -v jq >/dev/null 2>&1 || render_deny '[external-tool-policy-error] jq is unavailable; refusing an unclassified ship tool call'
  TOOL=$(printf '%s' "$PAYLOAD" | jq -er '(.tool_name // .toolName) | strings | select(length > 0)' 2>/dev/null) \
    || render_deny '[external-tool-policy-error] PreToolUse payload lacks a tool name; refusing an unclassified ship tool call'
  INPUT_JSON=$(printf '%s' "$PAYLOAD" | jq -cer '(.tool_input // .toolInput // {}) | objects' 2>/dev/null) \
    || render_deny '[external-tool-policy-error] PreToolUse payload has invalid tool input; refusing an unclassified ship tool call'
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) \
  || render_deny '[external-tool-policy-error] policy code root is unavailable; refusing the ship tool call'
POLICY="$SCRIPT_DIR/fm-external-tool-command-policy.mjs"
command -v node >/dev/null 2>&1 \
  || render_deny '[external-tool-policy-error] Node.js is unavailable; refusing the ship tool call'
[ -f "$POLICY" ] \
  || render_deny '[external-tool-policy-error] semantic policy executable is unavailable; refusing the ship tool call'

ARGS=(--brief "$BRIEF")
if [ "$VALIDATE" -eq 1 ]; then
  ARGS+=(--validate)
else
  ARGS+=(--tool "$TOOL" --input-json "$INPUT_JSON")
  [ "$COMMAND_SET" -eq 0 ] || ARGS+=(--command "$COMMAND")
fi
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-external-tool-policy.XXXXXX") \
  || render_deny '[external-tool-policy-error] cannot create a private policy error buffer; refusing the ship tool call'
POLICY_OUTPUT=$(node "$POLICY" "${ARGS[@]}" 2>"$ERR_FILE")
STATUS=$?
POLICY_ERROR=$(cat "$ERR_FILE" 2>/dev/null || true)
rm -f "$ERR_FILE"
if [ "$STATUS" -ne 0 ]; then
  [ -n "$POLICY_ERROR" ] || POLICY_ERROR='semantic policy failed without a reason'
  render_deny "[external-tool-policy-error] $POLICY_ERROR"
fi
[ "$VALIDATE" -eq 0 ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
case "$DECISION" in
  allow) exit 0 ;;
  deny)
    REST=${POLICY_OUTPUT#*"$TAB"}
    [ "$REST" != "$POLICY_OUTPUT" ] || render_deny '[external-tool-policy-error] semantic policy returned an invalid deny result'
    CODE=${REST%%"$TAB"*}
    REASON=${REST#*"$TAB"}
    [ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] \
      || render_deny '[external-tool-policy-error] semantic policy returned an incomplete deny result'
    render_deny "[$CODE] $REASON"
    ;;
  *) render_deny '[external-tool-policy-error] semantic policy returned an invalid decision' ;;
esac
