#!/usr/bin/env bash
# Antigravity (agy) Stop-parked primary supervision hook (.agents/hooks.json).
#
# Antigravity evaluates project-local .agents/hooks.json (Stop event) at the
# end of every agent turn. Like Cursor, Antigravity does not expose an
# asynchronous background rewake channel on Stop, so this hook parks a bounded
# foreground `bin/fm-watch.sh --timeout <poll>` inside the Stop hook itself:
#   - exit 0 (actionable wake drained): reset state/.turnend-blocks and return
#     {"decision":"continue","reason":"<wake-output>"} on stdout so Antigravity
#     immediately starts a follow-up supervision turn with the wake output.
#   - exit 2 (poll timeout while work remains in flight): return
#     {"decision":"continue","reason":"[supervision-park] ..."} so the agent
#     briefly ends its turn and re-parks the Stop watcher for the next window.
#   - exit 3 (fleet became empty while parked): reset state/.turnend-blocks,
#     emit {}, and let the turn end cleanly.
#   - exit 1 (or unexpected failure): delegate to `bin/fm-turnend-guard.sh --agy`
#     for the bounded 3-block repair nag before failing open.
#
# Guard rails before parking:
#   - Stand down in crewmate/scout linked worktrees (fm_primary_scope_matches).
#   - Pass through non-normal terminationReason values (anything non-empty
#     other than NO_TOOL_CALL) with {} without invoking fm-watch.sh.
#   - Pass through when executionNum reaches the loop ceiling (default 4,
#     overridable via FM_AGY_TURNEND_LOOP_CEILING) with {} without invoking
#     fm-watch.sh.
#   - Verify session-lock ownership via bin/fm-session-lock-lib.sh so a
#     read-only or foreign session never steals supervision.
#   - Record a unique claim in state/.agy-park-owner before parking and yield
#     cleanly with {} if a newer Stop hook superseded this park while waiting.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}

allow_stop() {
  printf '{}\n'
  exit 0
}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow_stop
command -v jq >/dev/null 2>&1 || allow_stop

fm_primary_scope_matches "$FM_ROOT" "$STATE" || allow_stop

TERM_REASON=$(printf '%s' "$PAYLOAD" | jq -r '.terminationReason // empty' 2>/dev/null || true)
if [ -n "$TERM_REASON" ] && [ "$TERM_REASON" != "NO_TOOL_CALL" ]; then
  allow_stop
fi

EXEC_NUM=$(printf '%s' "$PAYLOAD" | jq -r 'if (.executionNum | type) == "number" then (.executionNum | floor | tostring) else "" end' 2>/dev/null || true)
LOOP_CEILING=${FM_AGY_TURNEND_LOOP_CEILING:-4}
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=4 ;; esac
if [ -n "$EXEC_NUM" ] && [ "$EXEC_NUM" -ge "$LOOP_CEILING" ]; then
  allow_stop
fi

if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$LOCK_PID" || allow_stop
  fm_harness_pid_alive "$LOCK_PID" && allow_stop
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || allow_stop
  fm_session_lock_owned_by_self "$STATE" || allow_stop
fi

[ -e "$STATE/.afk" ] && allow_stop

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  allow_stop
fi

mkdir -p "$STATE" 2>/dev/null || true
PARK_OWNER_FILE="$STATE/.agy-park-owner"
PARK_OWNER="$$:$(date +%s):${RANDOM:-0}"
printf '%s\n' "$PARK_OWNER" > "$PARK_OWNER_FILE"

POLL_TIMEOUT="${FM_AGY_PARK_POLL:-${FM_AGY_PARK_TIMEOUT:-330}}"
case "$POLL_TIMEOUT" in ''|*[!0-9]*|0) POLL_TIMEOUT=330 ;; esac

WATCH_OUT=$("$SCRIPT_DIR/fm-watch.sh" --timeout "$POLL_TIMEOUT" 2>&1)
WATCH_RC=$?

CURRENT_OWNER=$(cat "$PARK_OWNER_FILE" 2>/dev/null || true)
if [ "$CURRENT_OWNER" != "$PARK_OWNER" ]; then
  allow_stop
fi
rm -f "$PARK_OWNER_FILE" 2>/dev/null || true

case "$WATCH_RC" in
  0)
    rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
    jq -cn --arg r "$WATCH_OUT" '{decision:"continue",reason:$r}'
    exit 0
    ;;
  2)
    jq -cn --arg r "[supervision-park] No actionable wake arrived within ${POLL_TIMEOUT}s while crewmates remain in flight. End your turn briefly so the Antigravity Stop hook can re-park the watcher." '{decision:"continue",reason:$r}'
    exit 0
    ;;
  3)
    rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
    allow_stop
    ;;
  *)
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --agy
    exit 0
    ;;
esac
