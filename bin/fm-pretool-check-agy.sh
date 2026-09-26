#!/usr/bin/env bash
# AGY PreToolUse adapter: seats subagent delegation, watcher arm, and cd guards.
#
# Registered in tracked .agents/hooks.json for AGY's `PreToolUse` step with
# matcher "*". It intercepts tool calls in a genuine primary session and applies:
#   1. Delegation guard: bin/fm-subagent-pretool-check.sh denies delegation-shaped
#      tool calls outside Firstmate's managed fleet.
#   2. Watcher arm policy: bin/fm-arm-pretool-check.sh denies backgrounded, piped,
#      or bundled watcher execution.
#   3. Cd guard: bin/fm-cd-pretool-check.sh denies persistent cd into projects/.
#
# The script always outputs valid AGY JSON on stdout:
#   {"decision": "allow"} or {"decision": "deny", "reason": "<explanation>"}
# and exits 0 so AGY parses the decision cleanly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

allow_tool() {
  printf '{"decision": "allow"}\n'
  exit 0
}

deny_tool() {  # <reason>
  local reason=$1
  command -v jq >/dev/null 2>&1 || {
    printf '{"decision": "deny", "reason": "tool execution denied by firstmate policy"}\n'
    exit 0
  }
  jq -n --arg r "$reason" '{"decision": "deny", "reason": $r}'
  exit 0
}

# Silent allow in non-primary scope (crew/scout worktree or foreign repo).
fm_primary_scope_matches "$FM_ROOT" "$STATE" || allow_tool

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow_tool
command -v jq >/dev/null 2>&1 || allow_tool

TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.name // empty' 2>/dev/null || true)
[ -n "$TOOL_NAME" ] || allow_tool

# 1. Delegation guard: check tool name against delegation stems
SUB_OUT=$("$SCRIPT_DIR/fm-subagent-pretool-check.sh" --tool "$TOOL_NAME" 2>&1)
SUB_RC=$?
if [ "$SUB_RC" -eq 2 ]; then
  REASON=$(printf '%s\n' "$SUB_OUT" | jq -r '.reason // .systemMessage // empty' 2>/dev/null || true)
  [ -n "$REASON" ] || REASON="$TOOL_NAME: delegation tool cannot run outside firstmate fleet supervision"
  deny_tool "$REASON"
fi

# 2. Command-based checks for command execution tools
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.args.CommandLine // .toolCall.args.command // .toolCall.args.cmd // empty' 2>/dev/null || true)
if [ -n "$CMD" ]; then
  # Check watcher-arm command policy
  ARM_OUT=$("$SCRIPT_DIR/fm-arm-pretool-check.sh" --command "$CMD" 2>&1)
  ARM_RC=$?
  if [ "$ARM_RC" -eq 2 ]; then
    REASON=$(printf '%s\n' "$ARM_OUT" | jq -r '.reason // .systemMessage // empty' 2>/dev/null || true)
    [ -n "$REASON" ] || REASON="protected watcher command policy denied: $CMD"
    deny_tool "$REASON"
  fi

  # Check persistent cd policy
  CD_OUT=$("$SCRIPT_DIR/fm-cd-pretool-check.sh" --command "$CMD" 2>&1)
  CD_RC=$?
  if [ "$CD_RC" -eq 2 ]; then
    REASON=$(printf '%s\n' "$CD_OUT" | jq -r '.reason // .systemMessage // empty' 2>/dev/null || true)
    [ -n "$REASON" ] || REASON="persistent cd command policy denied: $CMD"
    deny_tool "$REASON"
  fi
fi

allow_tool
