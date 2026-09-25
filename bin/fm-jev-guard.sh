#!/usr/bin/env bash
# fm-jev-guard.sh - PreToolUse transport for the Jev dynamic delegation guardrail.
#
# Intercepts Bash tool calls in Firstmate's primary supervisor workspace (w1).
# Allows legitimate supervisory actions (draining wakes, beads, steering workers).
# Denies hands-on implementation, remote SSH, package installations, service
# restarts, and project edits, steering Firstmate to delegate to Second Mates.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-jev-guard.sh [--claude|--cursor]
#   bin/fm-jev-guard.sh --command '<cmd>' [--claude|--cursor]
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-jev-guard.sh [--command <cmd>] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok/Claude/Cursor/Codex).
Fires only in the real primary firstmate checkout (w1); it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo.
Exits 0 to allow and 2 to deny commands that violate supervisor delegation boundaries.
The deny reason is written to stderr, with a Grok/Pi decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0.
Malformed transport or unavailable classifier runtime fail open (exit 0).
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

PAYLOAD=""
if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  
  HOOK_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  if [ -f "$HOOK_LIB" ]; then
    # shellcheck source=bin/fm-hook-host-lib.sh
    . "$HOOK_LIB"
    if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
      exit 0
    fi
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0

# Scope check: apply only in the primary checkout (git-dir == git-common-dir).
# Crewmate / scout task worktrees (linked git worktrees) are inert (exit 0).
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
if [ "${FM_TEST_PRIMARY:-0}" -ne 1 ]; then
  GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
  GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
  [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
fi

GUARD_PY="$FM_ROOT/bin/fm-jev-guard.py"
command -v python3 >/dev/null 2>&1 || exit 0
[ -f "$GUARD_PY" ] || exit 0

# Invoke python guard engine with --check-only
POLICY_OUTPUT=$(python3 "$GUARD_PY" --command "$CMD" --check-only 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0

REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}

REST2=${REST#*"$TAB"}
REASON=${REST2%%"$TAB"*}

REST3=${REST2#*"$TAB"}
DOMAIN=${REST3%%"$TAB"*}
SUGGESTED=${REST3#*"$TAB"}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

if [ -n "$SUGGESTED" ] && [ "$SUGGESTED" != "$REST3" ]; then
  DETAIL="[$CODE] $REASON (Domain: $DOMAIN; Suggested: $SUGGESTED)"
elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$REST3" ]; then
  DETAIL="[$CODE] $REASON (Domain: $DOMAIN)"
else
  DETAIL="[$CODE] $REASON"
fi

ESCAPED=$(json_escape "$DETAIL")

if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi

# Claude requires stdout to remain empty on deny, stderr receives systemMessage JSON
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
