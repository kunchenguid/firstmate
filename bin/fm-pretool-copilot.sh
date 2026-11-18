#!/usr/bin/env bash
# GitHub Copilot CLI preToolUse adapter for the primary's seatbelts.
#
# Registered in tracked .github/hooks/firstmate-primary.json. It runs the three
# existing PreToolUse checks - bin/fm-arm-pretool-check.sh,
# bin/fm-cd-pretool-check.sh and bin/fm-subagent-pretool-check.sh, which stay
# the single owners of every decision and of their primary-checkout scope - and
# re-emits the first deny as Copilot's own decision object:
#   {"permissionDecision":"deny","permissionDecisionReason":"..."}
# on stdout with exit 0. Exit status 2 would also deny, but Copilot then shows
# only the generic `hook exited with code 2` and drops stderr (verified,
# copilot 1.0.105), so the reason would be invisible to the model.
#
# Copilot's native payload is {toolName, toolArgs:{command}, ...}. The checks
# read the Claude shape, so this adapter hands each one a synthesized
# {tool_name, tool_input:{command}} payload. That payload deliberately carries no
# `timestamp`, and each check runs with COPILOT_HOOK_DEPTH removed from its
# environment (Copilot sets it in every hook), so fm-hook-host-lib.sh does not
# take the payload for a Copilot-delivered duplicate and stand the check down.
#
# The shell checks run for Copilot's `bash` tool. The subagent check runs for
# every tool: Copilot starts a subagent with the `task` tool (verified, a
# preToolUse with toolName `task` precedes subagentStart).
#
# The whole adapter is scoped to a genuine primary home through
# bin/fm-primary-scope-lib.sh, the same owner the session-start wrapper and the
# subagent guard use. A worker's worktree can carry this tracked registration
# (Copilot loads project hooks once the worktree is trusted), and the watcher-arm
# check has no scope of its own, so without this gate a Copilot worker on a
# Firstmate project would be judged by the primary's seatbelts.
#
# Payloads raised by a subagent (they carry parentAgentId) are skipped, so the
# guard judges only the primary's own calls. Malformed or empty input, a missing
# jq, and every check's own inert and fail-open paths allow the call: this
# adapter prints nothing and exits 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e 'type == "object" and (has("parentAgentId") | not)' >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.toolName // empty) | strings' 2>/dev/null) || exit 0
[ -n "$TOOL" ] || exit 0
CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolArgs.command // empty) | strings' 2>/dev/null) || CMD=

# deny_reason <check> [args...]: run one check on the synthesized payload and
# print its deny reason when it denies.
deny_reason() {
  local synth err status
  synth=$(jq -cn --arg t "$TOOL" --arg c "$CMD" '{tool_name:$t, tool_input:{command:$c}}') || return 1
  err=$(printf '%s' "$synth" | env -u COPILOT_HOOK_DEPTH "$SCRIPT_DIR/$1" --claude 2>&1 >/dev/null); status=$?
  [ "$status" -eq 2 ] || return 1
  printf '%s' "$err" | jq -r '.systemMessage // empty' 2>/dev/null | head -n 1
}

REASON=
if [ "$TOOL" = bash ] && [ -n "$CMD" ]; then
  REASON=$(deny_reason fm-arm-pretool-check.sh)
  [ -n "$REASON" ] || REASON=$(deny_reason fm-cd-pretool-check.sh)
fi
[ -n "$REASON" ] || REASON=$(deny_reason fm-subagent-pretool-check.sh)
[ -n "$REASON" ] || exit 0

jq -cn --arg r "$REASON" '{permissionDecision:"deny",permissionDecisionReason:$r}'
exit 0
