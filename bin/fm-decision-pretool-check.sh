#!/usr/bin/env bash
# Stable tool-identity gate for captain-facing structured questions.
#
# The checker denies only the exact built-in structured-question tool names
# exposed by firstmate's verified primary harnesses.
# It never inspects question text, option counts, Bash command text, or any
# other tool arguments.
# See docs/decision-pretool-check.md for the complete contract, harness wiring,
# and verification record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-decision-pretool-check.sh [--claude|--grok]
#   bin/fm-decision-pretool-check.sh --tool-name <exact-name>
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2 and a native deny response for the selected adapter.
#   FAIL OPEN - empty or malformed input, missing jq, or an unknown argument.
#
# Claude and Codex consume the stderr deny with stdout empty.
# Grok consumes the stdout decision object selected by --grok.
# OpenCode consumes exit 2 plus stderr after passing --tool-name.
set -u

ADAPTER=default
TOOL_NAME=""
TOOL_NAME_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude)
      ADAPTER=claude
      shift
      ;;
    --grok)
      ADAPTER=grok
      shift
      ;;
    --tool-name)
      [ "$#" -gt 1 ] || exit 0
      TOOL_NAME=$2
      TOOL_NAME_SET=1
      shift 2
      ;;
    --tool-name=*)
      TOOL_NAME=${1#--tool-name=}
      TOOL_NAME_SET=1
      shift
      ;;
    *)
      exit 0
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || exit 0

if [ "$TOOL_NAME_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -er '
    if (.tool_name? | type) == "string" then .tool_name
    elif (.toolName? | type) == "string" then .toolName
    else empty
    end
  ' 2>/dev/null) || exit 0
fi

case "$TOOL_NAME" in
  AskUserQuestion|request_user_input|ask_user_question|question) ;;
  *) exit 0 ;;
esac

MESSAGE=$(cat <<'EOF'
[lavish-only] Built-in structured questions are disabled in firstmate sessions. For a multi-option decision, write the complete context to request.md and the ordered questions to questions.json using [{"key":"lowercase-slug","prompt":"Which option?","options":[{"value":"option-a","label":"Option A"},{"value":"option-b","label":"Option B"}]}], then run: lavish-axi create --id <lowercase-slug> --title '<title>' --request <request.md> --questions <questions.json> --destination data/<id>/captain-answer.toon. For a yes/no, ask in plain chat instead. Surface only the decision title and: Run: lavish answer <id>
EOF
) || exit 0

if [ "$ADAPTER" = grok ]; then
  jq -cn --arg reason "$MESSAGE" '{decision:"deny",reason:$reason}' || exit 0
  exit 2
fi

DENY=$(jq -cn --arg reason "$MESSAGE" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  },
  systemMessage: $reason
}') || exit 0
printf '%s\n' "$DENY" >&2
exit 2
