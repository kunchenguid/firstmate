#!/usr/bin/env bash
# Stable PreToolUse transport for the watcher-arm command policy.
#
# A firstmate primary must arm the watcher or run a Codex checkpoint as a
# standalone verified harness call.
# bin/fm-arm-command-policy.mjs is the sole owner of shell classification,
# protected execution identity, the blessed setup tree, and deny reason codes.
# This wrapper only acquires the harness payload, discovers the active roots,
# invokes that policy, and renders the established harness-specific responses.
# It never executes, sources, evaluates, or expands the submitted command.
# See docs/arm-pretool-check.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-arm-pretool-check.sh
#   bin/fm-arm-pretool-check.sh --command '<cmd>' [--background true|false]
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex.
# CLI mode is used by OpenCode and Pi after their adapters extract the exact
# command string.
# --background remains accepted for compatibility, but harness-native tracked
# background execution is not itself a policy signal.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0
BACKGROUND=""
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Exits 0 to allow and 2 to deny.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --background)
      [ "$#" -gt 1 ] || { echo "error: --background requires a value" >&2; exit 2; }
      BACKGROUND=$2
      shift 2
      ;;
    --background=*)
      BACKGROUND=${1#--background=}
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

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CMD" ] || exit 0
  # Kept for transport parity only.
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
fi

[ -n "$CMD" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
ACTIVE_HOME=${FM_HOME:-$ROOT}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" 2>/dev/null) || exit 0
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
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
