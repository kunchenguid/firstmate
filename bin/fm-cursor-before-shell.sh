#!/usr/bin/env bash
# Cursor beforeShellExecution adapter for firstmate primary seatbelts.
#
# Cursor Hooks pass a JSON payload with .command (and related fields) on stdin
# and expect a permission decision object on stdout. This wrapper extracts the
# command, runs the shared arm + cd pretool checks with --claude (empty stdout
# on deny so we control the Cursor response shape), and maps exit 2 into
# Cursor's {permission:"deny", user_message, agent_message} object.
#
# Fail open on empty/malformed transport or missing jq - never wedge the shell.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM="$SCRIPT_DIR/fm-arm-pretool-check.sh"
CD="$SCRIPT_DIR/fm-cd-pretool-check.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || { printf '%s\n' '{"permission":"allow"}'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' '{"permission":"allow"}'; exit 0; }

CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.command // .tool_input.command // .toolInput.command // empty)' 2>/dev/null) || {
  printf '%s\n' '{"permission":"allow"}'
  exit 0
}
[ -n "$CMD" ] || { printf '%s\n' '{"permission":"allow"}'; exit 0; }

deny_with() {
  local reason=$1
  jq -nc --arg reason "$reason" \
    '{permission:"deny", user_message:$reason, agent_message:$reason}'
  exit 0
}

arm_err=
arm_rc=0
arm_err=$("$ARM" --command "$CMD" --claude 2>&1 >/dev/null) || arm_rc=$?
if [ "$arm_rc" -eq 2 ]; then
  reason=$(printf '%s' "$arm_err" | jq -r '.reason // .message // empty' 2>/dev/null)
  [ -n "$reason" ] || reason=$(printf '%s' "$arm_err" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$reason" ] || reason='Watcher arm must use a tracked Cursor Shell background task, not shell &.'
  deny_with "$reason"
fi

cd_err=
cd_rc=0
cd_err=$("$CD" --command "$CMD" --claude 2>&1 >/dev/null) || cd_rc=$?
if [ "$cd_rc" -eq 2 ]; then
  reason=$(printf '%s' "$cd_err" | jq -r '.reason // .message // empty' 2>/dev/null)
  [ -n "$reason" ] || reason=$(printf '%s' "$cd_err" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$reason" ] || reason='Do not cd the primary shell into a project clone or worktree.'
  deny_with "$reason"
fi

printf '%s\n' '{"permission":"allow"}'
exit 0
