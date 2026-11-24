#!/usr/bin/env bash
# Antigravity (agy) non-blocking Stop-hook turn-end guard (.agents/hooks.json).
#
# Antigravity evaluates project-local .agents/hooks.json (Stop event) at the
# end of every agent turn synchronously. Because synchronous parking in Stop
# blocks the interactive agent loop and queues user input, Antigravity primary
# supervision uses a tracked background run_command task (WaitMsBeforeAsync: 500)
# for bin/fm-watch-arm.sh (or bin/fm-supervision-host.sh park), while this
# hook runs fast as a turn-end backstop delegating to bin/fm-turnend-guard.sh
# --agy.
#
# Guard rails before delegating:
#   - Stand down with {} when payload is empty, invalid, or jq is missing.
#   - Stand down in crewmate/scout linked worktrees (fm_primary_scope_matches).
#   - Pass through non-normal terminationReason values (anything non-empty
#     other than NO_TOOL_CALL) with {}.
#   - Pass through when continuationActive is true so a Stop-triggered
#     continuation never re-triggers the guard in a loop.
#   - Verify session-lock ownership via bin/fm-session-lock-lib.sh so a
#     read-only or foreign session never blocks turn completion.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

allow_stop() {
  printf '{}\n'
  exit 0
}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow_stop
command -v jq >/dev/null 2>&1 || allow_stop
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || allow_stop

fm_primary_scope_matches "$FM_ROOT" "$STATE" || allow_stop

TERM_REASON=$(printf '%s' "$PAYLOAD" | jq -r '.terminationReason // empty' 2>/dev/null || true)
if [ -n "$TERM_REASON" ] && [ "$TERM_REASON" != "NO_TOOL_CALL" ]; then
  allow_stop
fi

CONT_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r 'if .continuationActive == true then "true" else "false" end' 2>/dev/null || printf 'false')
[ "$CONT_ACTIVE" = "true" ] && allow_stop

if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$LOCK_PID" || allow_stop
  fm_harness_pid_alive "$LOCK_PID" && allow_stop
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || allow_stop
  fm_session_lock_owned_by_self "$STATE" || allow_stop
fi

printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --agy
exit 0
