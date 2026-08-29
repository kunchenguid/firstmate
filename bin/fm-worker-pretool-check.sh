#!/usr/bin/env bash
# Stable PreToolUse transport for the worker command guard.
#
# An autonomous crewmate or scout runs unattended with approvals disabled, so a
# command that escapes its task worktree - host privileges, a remote host, a
# host-wide git config, a rewritten history, a push onto master/main, or a live
# .env - has no human in front of it. This seatbelt refuses that class of tool
# call before it runs, for every worker harness fm-spawn.sh wires it into.
# bin/fm-worker-command-policy.mjs is the sole owner of the perimeter and of the
# deny/allow decision; it reuses the shell classifier owned by
# bin/fm-arm-command-policy.mjs. This wrapper only acquires the harness payload,
# invokes that policy, and renders the established harness-specific responses.
# It never executes, sources, evaluates, or expands the submitted command.
# See docs/worker-command-guard.md for the complete contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-worker-pretool-check.sh [--claude|--cursor]
#   bin/fm-worker-pretool-check.sh --command '<cmd>' [--path '<file>'] [--tool '<name>']
#
# Stdin mode extracts the command from .tool_input.command (Claude, Codex,
# Cursor) or .toolInput.command (Grok), the file path from the matching
# file_path/path field, and the harness's own tool name from tool_name/toolName.
# CLI mode is used by OpenCode and Pi after their adapters extract the exact
# values. A payload may carry any of the three.
#
# The tool name is forwarded as data, never interpreted here: the policy owner
# alone decides what a given tool means for the perimeter, so this transport
# still restates no rule.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status.
#
# FAIL CLOSED, deliberately unlike bin/fm-arm-pretool-check.sh and
# bin/fm-cd-pretool-check.sh. Those two guard a supervised primary against agent
# mistakes, where a false block costs more than a missed one. This guard is a
# security perimeter around an UNATTENDED worker, so an unusable classifier
# (missing node, missing jq, absent policy owner, unreadable payload, invalid
# policy response) denies and says why, rather than silently handing the worker
# an unguarded shell. bin/fm-spawn.sh refuses to launch a worker whose guard
# runtime is missing, so this path is the runtime backstop, not the first check.
set -u

CMD=""
FILE_PATH=""
TOOL_NAME=""
CLI_MODE=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-worker-pretool-check.sh [--command <cmd>] [--path <file>] [--tool <name>] [--claude|--cursor]

With neither --command nor --path, reads a PreToolUse-style JSON payload on
stdin (Grok toolInput, or Claude/Codex/Cursor tool_input).
Exits 0 to allow and 2 to deny a tool call outside the worker perimeter.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
An unusable classifier denies: this guard fails closed by design.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CLI_MODE=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CLI_MODE=1
      shift
      ;;
    --path)
      [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }
      FILE_PATH=$2
      CLI_MODE=1
      shift 2
      ;;
    --path=*)
      FILE_PATH=${1#--path=}
      CLI_MODE=1
      shift
      ;;
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL_NAME=$2
      shift 2
      ;;
    --tool=*)
      TOOL_NAME=${1#--tool=}
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

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# Every refusal leaves through here, so the deny rendering is stated once for
# both the perimeter denials and the fail-closed ones.
refuse() {
  local detail escaped
  detail="[$1] $2"
  escaped=$(json_escape "$detail")
  if [ "$CURSOR_MODE" -eq 1 ]; then
    printf '{"permission":"deny","user_message":"%s"}\n' "$escaped"
    exit 0
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

if [ "$CLI_MODE" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || refuse worker-guard-unreadable "the worker command guard received an empty tool-call payload and cannot classify it; this guard refuses rather than allowing an unclassified call"
  command -v jq >/dev/null 2>&1 || refuse worker-guard-unavailable "the worker command guard needs jq to read the tool-call payload and jq is not installed; install jq or report this to firstmate"
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) \
    || refuse worker-guard-unreadable "the worker command guard could not parse the tool-call payload and refuses rather than allowing an unclassified call"
  FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.path // .toolInput.file_path // .toolInput.path // empty)' 2>/dev/null) \
    || refuse worker-guard-unreadable "the worker command guard could not parse the tool-call payload and refuses rather than allowing an unclassified call"
  TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) \
    || refuse worker-guard-unreadable "the worker command guard could not parse the tool-call payload and refuses rather than allowing an unclassified call"
fi

# A tool call carrying neither a command nor a path holds nothing this perimeter
# has an opinion about, so there is nothing to refuse.
[ -n "$CMD" ] || [ -n "$FILE_PATH" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) \
  || refuse worker-guard-unavailable "the worker command guard could not resolve its own location, so the perimeter cannot be applied"
POLICY="$SCRIPT_DIR/fm-worker-command-policy.mjs"
command -v node >/dev/null 2>&1 || refuse worker-guard-unavailable "the worker command guard needs node to classify a tool call and node is not installed; report this to firstmate"
[ -f "$POLICY" ] || refuse worker-guard-unavailable "the worker command guard's policy owner is missing at $POLICY, so the perimeter cannot be applied"

POLICY_ARGS=()
[ -z "$CMD" ] || POLICY_ARGS+=(--command "$CMD")
[ -z "$FILE_PATH" ] || POLICY_ARGS+=(--path "$FILE_PATH")
[ -z "$TOOL_NAME" ] || POLICY_ARGS+=(--tool "$TOOL_NAME")

POLICY_OUTPUT=$(node "$POLICY" "${POLICY_ARGS[@]}" 2>/dev/null) \
  || refuse worker-guard-unavailable "the worker command guard's policy owner failed to classify this tool call, so it is refused rather than allowed"
[ -n "$POLICY_OUTPUT" ] || refuse worker-guard-unavailable "the worker command guard's policy owner returned no decision, so this tool call is refused rather than allowed"

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" != "allow" ] || exit 0
[ "$DECISION" = "deny" ] || refuse worker-guard-unavailable "the worker command guard's policy owner returned an unrecognized decision, so this tool call is refused rather than allowed"

REST=${POLICY_OUTPUT#*"$TAB"}
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] \
  || refuse worker-guard-unavailable "the worker command guard's policy owner returned a malformed denial, so this tool call is refused rather than allowed"

refuse "$CODE" "$REASON"
