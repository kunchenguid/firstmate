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
# AGY payloads (`.toolCall.name` + `.toolCall.args`, camelCase) are detected in
# stdin mode and handled with the AGY output contract: exactly ONE decision
# object is printed on stdout (`{"decision":"allow"}` or
# `{"decision":"deny","reason":"..."}`), the exit status is always 0 (AGY does
# not use exit codes as a decision channel), and malformed transport fails
# open. Write-tool targets (`TargetFile`/`Filepath`/`FilePath`/`file_path`
# anywhere in `toolCall.args`) and the `run_command` working directory
# (`Cwd`/`cwd`/`WorkingDirectory`, else `workspacePaths[0]`) are judged by the
# same policy. `FM_ALLOW_PROJECTS_WRITE=1` allows everything (captain-approved
# escape).
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
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh" 2>/dev/null || true
  if command -v fm_hook_payload_is_foreign_host >/dev/null 2>&1; then
    if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD" 2>/dev/null; then
      exit 0
    fi
  fi
  # AGY payload shape: .toolCall.name / .toolCall.args (camelCase). AGY hooks
  # read stdout as the only decision channel, so every path below prints
  # exactly one decision object and exits 0 - never exit 2, never silent.
  agy_print_allow() {
    printf '{"decision":"allow"}\n'
    exit 0
  }
  agy_print_deny() {  # <reason>
    AGY_ESCAPED=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
    printf '{"decision":"deny","reason":"%s"}\n' "$AGY_ESCAPED"
    exit 0
  }
  AGY_TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.name // empty' 2>/dev/null) || AGY_TOOL=""
  if [ -n "$AGY_TOOL" ]; then
    [ "${FM_ALLOW_PROJECTS_WRITE:-}" = "1" ] && agy_print_allow
    SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || agy_print_allow
    ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || agy_print_allow
    command -v node >/dev/null 2>&1 || agy_print_allow
    POLICY="$ROOT/bin/fm-selfdo-policy.mjs"
    [ -f "$POLICY" ] || agy_print_allow
    # Inert outside the real primary home (crewmate/scout task worktrees).
    ACTIVE_HOME=${FM_HOME:-$ROOT}
    STATE=${FM_STATE_OVERRIDE:-$ACTIVE_HOME/state}
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || agy_print_allow
    fm_primary_scope_matches "$ROOT" "$STATE" 2>/dev/null || agy_print_allow
    AGY_TOOL_LC=$(printf '%s' "$AGY_TOOL" | tr '[:upper:]' '[:lower:]')
    case "$AGY_TOOL_LC" in
      write_to_file|replace_file_content|multi_replace_file_content)
        # Every target anywhere in the write tool's args: the top-level target
        # and its spellings, plus the per-operation targets in a multi-edit.
        AGY_TARGETS=$(printf '%s' "$PAYLOAD" | jq -r '
          [.. | objects
            | (.TargetFile // .Filepath // .FilePath // .file_path // empty)
            | select(type == "string" and length > 0)] | unique[]
        ' 2>/dev/null) || AGY_TARGETS=""
        while IFS= read -r AGY_TARGET; do
          [ -n "$AGY_TARGET" ] || continue
          AGY_OUT=$(node "$POLICY" --path "$AGY_TARGET" 2>/dev/null) || AGY_OUT=""
          case "$AGY_OUT" in
            deny*)
              AGY_REASON=$(printf '%s' "$AGY_OUT" | cut -f3-)
              [ -n "$AGY_REASON" ] || AGY_REASON="direct writes to projects/ are blocked - delegate project work via bin/fm-brief.sh and bin/fm-spawn.sh"
              agy_print_deny "$AGY_REASON"
              ;;
          esac
        done <<AGY_EOF
$AGY_TARGETS
AGY_EOF
        agy_print_allow
        ;;
      run_command)
        # Judge the submitted command; when the working directory itself sits
        # under projects/, prefix it so the command is judged against that touch.
        AGY_CMD=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.args.CommandLine // .toolCall.args.command // .toolCall.args.Command // empty' 2>/dev/null) || AGY_CMD=""
        AGY_CWD=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.args.Cwd // .toolCall.args.cwd // .toolCall.args.WorkingDirectory // .workspacePaths[0] // empty' 2>/dev/null) || AGY_CWD=""
        AGY_JUDGE=$AGY_CMD
        case "$AGY_CWD" in
          ""|null) ;;
          *)
            AGY_CWD_OUT=$(node "$POLICY" --path "$AGY_CWD" 2>/dev/null) || AGY_CWD_OUT=""
            case "$AGY_CWD_OUT" in
              deny*) AGY_JUDGE="cd $AGY_CWD && $AGY_CMD" ;;
            esac
            ;;
        esac
        if [ -n "$AGY_JUDGE" ] && [ "$AGY_JUDGE" != "null" ]; then
          AGY_OUT=$(node "$POLICY" --command "$AGY_JUDGE" 2>/dev/null) || agy_print_allow
          case "$AGY_OUT" in
            deny*)
              AGY_REASON=$(printf '%s' "$AGY_OUT" | cut -f3-)
              [ -n "$AGY_REASON" ] || AGY_REASON="direct writes to projects/ are blocked - delegate project work via bin/fm-brief.sh and bin/fm-spawn.sh"
              agy_print_deny "$AGY_REASON"
              ;;
          esac
        fi
        agy_print_allow
        ;;
      *)
        agy_print_allow
        ;;
    esac
  fi
  # AGY-shaped marker with an unparseable body: fail open but keep the AGY
  # contract of exactly one decision object on stdout.
  if [ -z "$AGY_TOOL" ]; then
    case "$PAYLOAD" in
      *'"toolCall"'*) agy_print_allow ;;
    esac
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
