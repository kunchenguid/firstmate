#!/usr/bin/env bash
# Antigravity CLI (agy) `Stop` hook adapter for a firstmate PRIMARY session:
# background-notify supervision backstop.
#
# Registered in tracked .agents/hooks.json under `Stop`. Antigravity runs this
# hook at every turn boundary when the agent execution loop terminates with
# `terminationReason: "NO_TOOL_CALL"` (or `"model_stop"`).
#
# Normal supervision on an Antigravity primary arms `bin/fm-watch-arm.sh` via
# Antigravity's tracked background `run_command` tool (`WaitMsBeforeAsync`), and
# Antigravity's reactive wakeup resumes the agent out-of-band when the watcher
# task completes with an actionable wake.
#
# This non-blocking `Stop` hook enforces three turn-end guarantees in <20ms:
#   1. ALLOW      when a healthy watcher cycle is already running (the active
#                 background `run_command` task), when no active in-flight work
#                 requires supervision, or when away/quiet mode owns supervision,
#                 return `{"decision": "allow"}` immediately.
#   2. QUEUED     when unread actionable wakes are already sitting in
#                 `state/.wake-queue` at turn end, return
#                 `{"decision": "continue", "reason": "..."}` so the session
#                 drains and handles them before stopping.
#   3. BACKSTOP   when active tasks are in flight and no healthy watcher cycle
#                 is running, query `bin/fm-turnend-guard.sh --agy` and return
#                 its repair instruction as a bounded `continue` follow-up so
#                 the session arms `bin/fm-watch-arm.sh` via `run_command`
#                 before ending the turn.
#
# EXIT CONTRACT:
# Antigravity CLI expects exit status 0 and a JSON object on stdout:
#   {"decision": "allow"}              - allow the agent to stop normally.
#   {"decision": "continue", "reason"} - re-enter the loop with system message.
#
# LOOP BOUNDING:
# FM_AGY_TURNEND_LOOP_CEILING bounds consecutive hook-driven turns without captain
# intervention so an uncontrolled loop cannot run forever.
# FM_AGY_TURNEND_BLOCK_BUDGET bounds consecutive repair follow-ups when the
# session fails to establish a healthy watcher cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
OWNER_LOCK="$STATE/.agy-park-owner.lock"
BUDGET_FILE="$STATE/.turnend-agy-blocks"

LOOP_CEILING=${FM_AGY_TURNEND_LOOP_CEILING:-180}
BLOCK_BUDGET=${FM_AGY_TURNEND_BLOCK_BUDGET:-3}
LOCK_ATTEMPTS=${FM_AGY_LOCK_ATTEMPTS:-50}
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=180 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=50 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

emit_allow() {
  printf '{"decision":"allow"}\n'
  exit 0
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || emit_allow
command -v jq >/dev/null 2>&1 || emit_allow

# Cursor or other foreign host payload stand-down.
fm_hook_payload_is_foreign_host "$PAYLOAD" && emit_allow

TERMINATION_REASON=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("terminationReason") then
    if ((.terminationReason | type) == "string") then .terminationReason else error("terminationReason") end
  else "model_stop"
  end
' 2>/dev/null) || emit_allow

# Only guard when model stopped naturally. If stopped due to max_steps_exceeded, error, or cancel, allow.
case "$TERMINATION_REASON" in
  model_stop|NO_TOOL_CALL|'') ;;
  *) emit_allow ;;
esac

LOOP_COUNT=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("executionNum") then
    if ((.executionNum | type) == "number") then (.executionNum | floor) else error("executionNum") end
  elif has("loop_count") then
    if ((.loop_count | type) == "number") then (.loop_count | floor) else error("loop_count") end
  else 0
  end
' 2>/dev/null) || emit_allow
case "$LOOP_COUNT" in ''|*[!0-9]*) LOOP_COUNT=0 ;; esac

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.conversationId // .session_id // "unknown"' 2>/dev/null || printf 'unknown')
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) SESSION_ID=unknown ;; esac

fm_primary_scope_matches "$FM_ROOT" "$STATE" || emit_allow

lock_acquire_bounded() {  # <lock>
  local lock=$1 attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] && sleep 0.1
  done
  return 1
}

budget_read() {
  local session count
  BUDGET_COUNT=0
  [ -f "$BUDGET_FILE" ] || return 0
  session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$session" = "$SESSION_ID" ] && BUDGET_COUNT=$count
  return 0
}

budget_write() {  # <count>
  local tmp="$BUDGET_FILE.tmp.$$" status=0
  [ ! -d "$BUDGET_FILE" ] || return 1
  printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$1" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null \
    || status=1
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

budget_reset() {
  rm -f "$BUDGET_FILE" 2>/dev/null
}

current_session_still_ours() {
  local owner
  owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner" = "$OWNER_ID" ] || return 1
  fm_session_lock_owned_by_self "$STATE"
}

budget_reset_if_ours() {
  lock_acquire_bounded "$OWNER_LOCK" || emit_allow
  if ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    emit_allow
  fi
  budget_reset || {
    fm_lock_release "$OWNER_LOCK"
    emit_allow
  }
  fm_lock_release "$OWNER_LOCK"
}

emit_continue() {  # <kind> <body> [reset-budget]
  local kind=$1 body=$2 reset_budget=${3-} encoded response
  fm_operational_input_encode "$kind" "$body" encoded || emit_allow
  response=$(jq -n --arg m "$encoded" '{decision:"continue",reason:$m}' 2>/dev/null) || emit_allow
  lock_acquire_bounded "$OWNER_LOCK" || emit_allow
  if ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    emit_allow
  fi
  if [ "$reset_budget" = reset-budget ] && ! budget_reset; then
    fm_lock_release "$OWNER_LOCK"
    emit_allow
  fi
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

emit_repair_followup() {  # <reason>
  local reason=$1 prior count body encoded response
  current_session_still_ours || emit_allow
  budget_read
  [ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ] || emit_allow
  prior=$BUDGET_COUNT
  count=$((prior + 1))

  body="TURN WOULD END BLIND - supervision is off (nag $count of $BLOCK_BUDGET).

$reason"
  fm_operational_input_encode turn-end-guard "$body" encoded || emit_allow
  response=$(jq -n --arg m "$encoded" '{decision:"continue",reason:$m}' 2>/dev/null) || emit_allow

  lock_acquire_bounded "$OWNER_LOCK" || emit_allow
  if ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    emit_allow
  fi
  budget_read
  if [ "$BUDGET_COUNT" -ne "$prior" ] || ! budget_write "$count"; then
    fm_lock_release "$OWNER_LOCK"
    emit_allow
  fi
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

# Only the lock-owning session may enforce supervision.
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in ''|*[!0-9]*) emit_allow ;; esac
  fm_harness_pid_alive "$LOCK_PID" && emit_allow
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || emit_allow
  fm_session_lock_owned_by_self "$STATE" || emit_allow
fi

OWNER_ID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$OWNER_ID" in ''|*[!0-9]*) emit_allow ;; esac

# Inner loop ceiling.
if [ "$LOOP_COUNT" -ge "$LOOP_CEILING" ]; then
  [ "$LOOP_COUNT" -eq "$LOOP_CEILING" ] || emit_allow
  fm_supervision_needed "$STATE" "$GRACE" || emit_allow
  emit_continue turn-end-guard "FIRSTMATE SUPERVISION CEILING REACHED - this session has taken $LOOP_COUNT consecutive hook-driven turns without a captain message, so automatic continuation stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically after the captain's next message."
fi

# Away mode owns the watcher and its own triage; never block and never continue.
if [ -e "$STATE/.afk" ]; then
  emit_allow
fi

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  emit_allow
fi

# Unread wakes already queued at turn end must be drained before stopping.
if [ -s "$STATE/.wake-queue" ]; then
  WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$STATE/.wake-queue" 2>/dev/null | head -8)
  [ -n "$WAKE" ] || WAKE=$(head -8 "$STATE/.wake-queue" 2>/dev/null || true)
  emit_continue watcher "firstmate watcher wake - queued supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. If the home still needs supervision after handling, re-arm bin/fm-watch-arm.sh as its own Antigravity tracked background run_command task (WaitMsBeforeAsync: 1000)." reset-budget
fi

# Active task predicate: an in-flight task requires supervision unless it has
# already been recorded as an open PR awaiting external review/merge (pr= in meta)
# with an idle worker. Tasks that have not yet had their PR registered or that
# use local-only branches require supervision for landing, teardown, or recovery.
fm_has_active_tasks() {
  local state=$1 meta id b_state
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)

    # Any pending turn-ended notification for this task requires immediate supervision.
    [ -f "$state/$id.turn-ended" ] && return 0

    # If the task has not yet been registered as an open PR (bin/fm-pr-check.sh),
    # it is actively executing or awaiting landing/teardown/reporting.
    if ! grep -q '^pr=' "$meta" 2>/dev/null; then
      return 0
    fi

    # For PR-registered tasks: if the worker is still actively executing,
    # it is still an active task.
    if [ -f "$state/$id.busy-state" ]; then
      b_state=$(sed -n 's/.*state=\([a-z]*\).*/\1/p' "$state/$id.busy-state" 2>/dev/null || true)
      [ "$b_state" = "busy" ] && return 0
    fi
  done
  return 1
}

# Antigravity CLI supervision requires active in-flight work, pending wakes, or active Relay watch.
# Background checks (e.g. contributions poll, PR merge polls) and PR-registered idle tasks
# do not require an active background watcher task.
if { [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || ! fm_has_active_tasks "$STATE"; } && [ ! -f "$STATE/x-watch.check.sh" ]; then
  budget_reset_if_ours
  emit_allow
fi

# Normal Option A path: a verified live watcher cycle with a fresh beacon
# (armed via Antigravity's tracked background run_command tool) allows the turn
# to end immediately (<10ms) while Antigravity's reactive wakeup monitors exit.
if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  budget_reset_if_ours
  emit_allow
fi

# Active work is in flight with no healthy watcher cycle. Query shared turn-end guard.
GUARD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-agy.XXXXXX") || emit_allow
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --agy 2>"$GUARD_ERR"
GUARD_RC=$?
REASON=$(cat "$GUARD_ERR" 2>/dev/null || true)
rm -f "$GUARD_ERR" 2>/dev/null || true
[ "$GUARD_RC" -eq 2 ] || emit_allow

[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
emit_repair_followup "$REASON"
