#!/usr/bin/env bash
# Nonblocking agentStop backstop for a GitHub Copilot CLI primary.
#
# Normal Copilot supervision runs bin/fm-watch-arm.sh as one harness-tracked
# asynchronous shell task.
# This hook never runs or waits for that task itself.
# It only blocks the stop long enough to tell the model to start the missing
# asynchronous task, with a bounded continuation ledger below Copilot's own
# eight-block override.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONTINUATION_FILE="$STATE/.turnend-copilot-continuations"
CONTINUATION_LOCK="$STATE/.turnend-copilot-continuations.lock"
LOOP_CEILING=${FM_COPILOT_TURNEND_LOOP_CEILING:-7}
LOCK_ATTEMPTS=${FM_COPILOT_LOCK_ATTEMPTS:-50}
GUARD_ERR=

case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=7 ;; esac
case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=50 ;; esac

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  [ -n "$GUARD_ERR" ] && rm -f "$GUARD_ERR" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '
  if type == "object" and (.sessionId | type) == "string" then .sessionId
  elif type == "object" and (.session_id | type) == "string" then .session_id
  else error("sessionId")
  end
' 2>/dev/null) || exit 0
STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type == "object" and (.stop_hook_active | type) == "boolean" then .stop_hook_active
  else error("stop_hook_active")
  end
' 2>/dev/null) || exit 0
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0
[ -e "$STATE/.afk" ] && exit 0

lock_acquire_bounded() {
  local attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$CONTINUATION_LOCK" && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] && sleep 0.1
  done
  return 1
}

continuation_read() {
  local session count
  LOOP_COUNT=0
  if [ "$STOP_HOOK_ACTIVE" != true ]; then
    rm -f "$CONTINUATION_FILE" 2>/dev/null || true
    return 0
  fi
  session=$(sed -n '1s/^session=//p' "$CONTINUATION_FILE" 2>/dev/null || true)
  count=$(sed -n '2s/^count=//p' "$CONTINUATION_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=1 ;; esac
  if [ "$session" = "$SESSION_ID" ]; then
    LOOP_COUNT=$count
  else
    LOOP_COUNT=1
  fi
}

continuation_write() {
  local count=$1 tmp="$CONTINUATION_FILE.tmp.$$" status=0
  printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$count" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$CONTINUATION_FILE" 2>/dev/null \
    || status=1
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

mark_parent_busy() {
  local parent_state=${FM_COPILOT_PARENT_STATE:-}
  local parent_id=${FM_COPILOT_PARENT_TASK_ID:-}
  local parent_gen=${FM_COPILOT_PARENT_BUSY_GEN:-}
  if [ -z "$parent_state$parent_id$parent_gen" ]; then
    return 0
  fi
  [ -n "$parent_state" ] && [ -n "$parent_id" ] && [ -n "$parent_gen" ] || return 1
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$parent_state" "$parent_id" busy \
    --gen "$parent_gen" --source copilot-hook --event stop-continuation \
    >/dev/null 2>&1
}

emit_block() {
  local body=$1 count=$2 encoded response
  fm_operational_input_encode turn-end-guard "$body" encoded || exit 0
  response=$(jq -n --arg m "$encoded" '{decision:"block",reason:$m}' 2>/dev/null) || exit 0

  lock_acquire_bounded || exit 0
  if ! fm_session_lock_owned_by_self "$STATE" || [ -e "$STATE/.afk" ] \
    || ! mark_parent_busy || ! continuation_write "$count"; then
    fm_lock_release "$CONTINUATION_LOCK"
    exit 0
  fi
  printf '%s\n' "$response" || true
  fm_lock_release "$CONTINUATION_LOCK"
  exit 0
}

lock_acquire_bounded || exit 0
continuation_read
fm_lock_release "$CONTINUATION_LOCK"

GUARD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-copilot.XXXXXX") || exit 0
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --copilot 2>"$GUARD_ERR"
GUARD_RC=$?
REASON=$(cat "$GUARD_ERR" 2>/dev/null || true)
rm -f "$GUARD_ERR" 2>/dev/null || true
GUARD_ERR=
[ "$GUARD_RC" -eq 2 ] || exit 0

if [ "$LOOP_COUNT" -ge "$LOOP_CEILING" ]; then
  exit 0
fi
if [ "$LOOP_COUNT" -eq "$((LOOP_CEILING - 1))" ]; then
  emit_block "FIRSTMATE SUPERVISION FOLLOW-UP CEILING REACHED - this session has taken $LOOP_COUNT consecutive hook-driven turns without a captain message, so automatic recovery prompts stop here to bound the loop. Queued events remain durable. Run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. A real captain prompt resets the sequence." "$LOOP_CEILING"
fi

[ -n "$REASON" ] || REASON='tasks are in flight but no tracked asynchronous watcher task is active'
emit_block "$REASON" "$((LOOP_COUNT + 1))"
