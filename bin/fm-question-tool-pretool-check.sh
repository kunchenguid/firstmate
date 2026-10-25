#!/usr/bin/env bash
# PreToolUse guard that denies a structured question picker in a firstmate
# primary or secondmate session.
#
# Decisions are made directly or asked in plain chat.
# This script is the single owner of the denied names and of the
# primary-scope check. A linked worker copy stays inert, so a crewmate keeps
# whatever picker its own project offers.
#
# Denied names, compared after lowercasing and stripping every character that
# is not a letter or digit, so Claude's AskUserQuestion and Grok's
# ask_user_question are one entry:
#   askuserquestion          AskUserQuestion, ask_user_question
#   question                 OpenCode's question tool
#   functionsrequestuserinput  Codex functions.request_user_input
#
# Registrations that reach this script:
#   .claude/settings.json    matcher .*, --claude, inert when Grok loaded the
#                            Claude settings (Grok has its own hook)
#   .grok/hooks/fm-primary-question-tool.json
#   .codex/hooks.json        matcher functions.request_user_input
#   .opencode/plugins/fm-primary-question-tool.js
#
# Inspected and not wired, because no question-picker tool was verified there:
#   pi and pi-signed built-ins are read, bash, powershell, edit, write, grep,
#   find, and ls. omp is that Pi family. Kimi's primary surface has no
#   project tool-deny hook. Cursor's AskQuestion name is unverified.
# A tracked Claude permissions.deny entry is not used: it cannot be limited to
# a primary home, and linked worker copies inherit tracked project settings.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-question-tool-pretool-check.sh
#   bin/fm-question-tool-pretool-check.sh --tool '<tool-name>'
#
# Stdin mode reads .tool_name (Claude, Codex) or .toolName (Grok).
# --tool is the form OpenCode uses.
#
# ALLOW and INERT: exit 0, no output.
# DENY: exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped deny
# object on stdout unless --claude was supplied. Claude ignores a deny whose
# stdout is nonempty.
# Malformed or empty stdin, or missing jq for stdin transport, fails open.
set -u

# Exact normalized names. This list is the single owner of what is denied.
QUESTION_TOOLS='askuserquestion question functionsrequestuserinput'

TOOL=""
TOOL_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-question-tool-pretool-check.sh [--tool <tool-name>] [--claude]

With no --tool, reads a PreToolUse JSON payload on stdin (Claude/Codex
tool_name, or Grok toolName).
Denies a structured question picker in a genuine primary or secondmate home.
A linked worker copy and any non-firstmate repo are silent no-ops.
Exits 0 to allow and 2 to deny.
Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
fi

[ -n "$TOOL" ] || exit 0

# MCP tool names are chosen by the server. An exact normalized match cannot
# collide with mcp__server__tool, which keeps its server prefix.
case "$TOOL" in
  mcp__*) exit 0 ;;
esac

LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

MATCHED=""
for name in $QUESTION_TOOLS; do
  [ "$NORMALIZED" = "$name" ] || continue
  MATCHED=$name
  break
done
[ -n "$MATCHED" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# Same primary predicate as the session-start nudge and the delegation guard.
# A failure to confirm the home is inert, never a block.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

REASON="[question-picker] this session does not use a structured question picker. Decide, or ask in plain chat (blocked tool: $TOOL)."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
