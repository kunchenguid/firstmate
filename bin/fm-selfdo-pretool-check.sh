#!/usr/bin/env bash
# PreToolUse guard that blocks Jala's direct writes to projects/ or project worktrees.
# bin/fm-selfdo-policy.mjs owns the block/allow decision; this wrapper only
# scopes to the real primary checkout, acquires the harness payload, and renders
# the established harness responses. It never executes the submitted path/command.
# See bin/fm-selfdo-policy.mjs for the exact policy.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-selfdo-pretool-check.sh
#   bin/fm-selfdo-pretool-check.sh --path '<path>' | --command '<cmd>'
#
# Stdin mode extracts tool_input path/command for Claude/Codex/pi:
#   - For edit/write tools: .tool_input.path / .tool_input.file_path / .tool_input.filePath
#   - For bash: .tool_input.command / .toolInput.command
# CLI mode is used by OpenCode and Pi after their adapters extract the exact string.
#
# Exit/output contract (same as other seatbelts):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not the real primary checkout (crewmate/scout worktree): exit 0.
#   FAIL OPEN - malformed stdin, missing jq, missing Node/policy.
set -u

PATH_ARG=""
COMMAND_ARG=""
PATH_SET=0
COMMAND_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-selfdo-pretool-check.sh [--path <path>] [--command <cmd>] [--claude|--cursor]
With no --path/--command, reads PreToolUse JSON on stdin.
Exits 0 to allow and 2 to deny.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)
      [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }
      PATH_ARG=$2
      PATH_SET=1
      shift 2
      ;;
    --path=*)
      PATH_ARG=${1#--path=}
      PATH_SET=1
      shift
      ;;
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      COMMAND_ARG=$2
      COMMAND_SET=1
      shift 2
      ;;
    --command=*)
      COMMAND_ARG=${1#--command=}
      COMMAND_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
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

if [ "$PATH_SET" -eq 0 ] && [ "$COMMAND_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # Detect cursor duplicate like other guards.
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh" 2>/dev/null || true
  if command -v fm_hook_payload_is_foreign_host >/dev/null 2>&1; then
    if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD" 2>/dev/null; then
      exit 0
    fi
  fi
  # Try to extract a file path from various tool shapes.
  EXTRACTED_PATH=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.path // .tool_input.file_path // .tool_input.filePath // .tool_input.file // .toolInput.path // empty)' 2>/dev/null) || EXTRACTED_PATH=""
  EXTRACTED_CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || EXTRACTED_CMD=""
  if [ -n "$EXTRACTED_PATH" ]; then
    PATH_ARG=$EXTRACTED_PATH
    PATH_SET=1
  elif [ -n "$EXTRACTED_CMD" ]; then
    COMMAND_ARG=$EXTRACTED_CMD
    COMMAND_SET=1
  else
    # Fallback: if tool name is edit/write and payload has path in .tool_input
    # Try broader extraction.
    FALLBACK=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input // .toolInput // empty | to_entries[]? | select(.key | test("path|file";"i")) | .value' 2>/dev/null | head -1) || FALLBACK=""
    if [ -n "$FALLBACK" ]; then
      PATH_ARG=$FALLBACK
      PATH_SET=1
    else
      exit 0
    fi
  fi
fi

# Scope to genuine primary home - workers in worktrees must write there.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
ACTIVE_HOME=${FM_HOME:-$ROOT}
STATE=${FM_STATE_OVERRIDE:-$ACTIVE_HOME/state}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || exit 0
if ! fm_primary_scope_matches "$ROOT" "$STATE" 2>/dev/null; then
  exit 0
fi

POLICY="$ROOT/bin/fm-selfdo-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

if [ "$PATH_SET" -eq 1 ]; then
  POLICY_OUTPUT=$(node "$POLICY" --path "$PATH_ARG" 2>/dev/null) || exit 0
else
  POLICY_OUTPUT=$(node "$POLICY" --command "$COMMAND_ARG" 2>/dev/null) || exit 0
fi
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
