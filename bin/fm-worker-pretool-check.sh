#!/usr/bin/env bash
# Stable PreToolUse transport for Firstmate's worker-only PR merge denial.
#
# fm-worker-command-policy.mjs owns the semantic command decision and reuses the
# shell tokenizer exported by fm-arm-command-policy.mjs.
# This transport acts only in a workspace carrying a private spawn-time
# .fm-worker-guard registration bound to the active firstmate state directory.
# A tokenless workspace is inert. Once a worker registration is present,
# malformed registration, missing dependencies, malformed hook payload, or an
# invalid policy response denies the shell call rather than running unguarded.
#
# Usage:
#   <PreToolUse JSON on stdin> | fm-worker-pretool-check.sh --workspace <dir>
#   fm-worker-pretool-check.sh --workspace <dir> --command '<cmd>'
#
# Stdin mode reads Grok toolInput.command or Claude/Codex tool_input.command.
# OpenCode and Pi pass --command after extracting the exact shell command.
# --claude leaves stdout empty on denial as required by Claude Code.
set -u

WORKSPACE=""
CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-worker-pretool-check.sh --workspace <dir> [--command <cmd>] [--claude]

A registered Firstmate worker may use GitHub to push, open, inspect, and review
PRs, but merge-shaped GitHub commands are denied before execution.
A workspace without a spawn-time worker registration is left untouched.
Registered workers fail safely when guard dependencies or registration are bad.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      [ "$#" -gt 1 ] || { echo "error: --workspace requires a value" >&2; exit 2; }
      WORKSPACE=$2
      shift 2
      ;;
    --workspace=*) WORKSPACE=${1#--workspace=}; shift ;;
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*) CMD=${1#--command=}; CMD_SET=1; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$WORKSPACE" ] || exit 0
WORKSPACE_REAL=$(CDPATH='' cd -- "$WORKSPACE" 2>/dev/null && pwd -P) || exit 0
POINTER="$WORKSPACE_REAL/.fm-worker-guard"
[ -e "$POINTER" ] || [ -L "$POINTER" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

deny() {
  local code=$1 reason=$2 detail escaped
  detail="[$code] $reason"
  escaped=$(json_escape "$detail")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

unavailable() {
  deny worker-guard-unavailable "the registered Firstmate worker merge guard is unavailable or invalid; no shell command may run until firstmate repairs or relaunches this worker"
}

[ -f "$POINTER" ] && [ ! -L "$POINTER" ] || unavailable
[ "$(stat -f '%l' "$POINTER" 2>/dev/null || stat -c '%h' "$POINTER" 2>/dev/null || printf 0)" = 1 ] || unavailable
AUTH=$(sed -n 's/^auth=//p' "$POINTER" 2>/dev/null | tail -1)
VERSION=$(sed -n 's/^version=//p' "$POINTER" 2>/dev/null | tail -1)
[ "$VERSION" = fm-worker-guard-v1 ] || unavailable
case "$AUTH" in
  /*/state/.worker-guard.d/fm.????????????) : ;;
  *) unavailable ;;
esac
[ -f "$AUTH" ] && [ ! -L "$AUTH" ] || unavailable
[ "$(stat -f '%l' "$AUTH" 2>/dev/null || stat -c '%h' "$AUTH" 2>/dev/null || printf 0)" = 1 ] || unavailable
PERMS=$(stat -f '%Lp' "$AUTH" 2>/dev/null || stat -c '%a' "$AUTH" 2>/dev/null || printf '')
[ "$PERMS" = 600 ] || unavailable
AUTH_VERSION=$(sed -n 's/^version=//p' "$AUTH" 2>/dev/null | tail -1)
AUTH_WORKSPACE=$(sed -n 's/^workspace=//p' "$AUTH" 2>/dev/null | tail -1)
AUTH_CHECKER=$(sed -n 's/^checker=//p' "$AUTH" 2>/dev/null | tail -1)
[ "$AUTH_VERSION" = fm-worker-guard-v1 ] || unavailable
[ "$AUTH_WORKSPACE" = "$WORKSPACE_REAL" ] || unavailable
SCRIPT_REAL=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")
[ "$AUTH_CHECKER" = "$SCRIPT_REAL" ] || unavailable

if [ "$CMD_SET" -eq 0 ]; then
  command -v jq >/dev/null 2>&1 || unavailable
  PAYLOAD=$(cat 2>/dev/null) || unavailable
  [ -n "$PAYLOAD" ] || unavailable
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || unavailable
fi
[ -n "$CMD" ] || unavailable

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || unavailable
POLICY="$SCRIPT_DIR/fm-worker-command-policy.mjs"
command -v node >/dev/null 2>&1 || unavailable
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || unavailable
POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || unavailable
[ -n "$POLICY_OUTPUT" ] || unavailable

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = deny ] || {
  [ "$DECISION" = allow ] && exit 0
  unavailable
}
REST=${POLICY_OUTPUT#*"$TAB"}
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || unavailable
deny "$CODE" "$REASON"
