#!/usr/bin/env bash
# Antigravity CLI (agy) `Stop` hook adapter for a firstmate PRIMARY session: the park model.
#
# Registered in tracked .agents/hooks.json under `Stop`. Antigravity runs this
# hook SYNCHRONOUSLY at every turn boundary when the agent execution loop
# terminates with `terminationReason: "model_stop"`. One script owns both halves
# of Antigravity primary supervision:
#
#   PARK      while supervision is needed, foreground bin/fm-watch-arm.sh and
#             hold the turn boundary open until the watcher closes with an
#             actionable wake, then return {"decision": "continue", "reason": "..."}
#             on stdout. Antigravity re-enters the agent loop immediately with the
#             reason injected as a system message. No model tokens are spent
#             while parked. The next turn end parks again, so the arm/re-arm loop
#             is hook-owned, never model-memory-owned.
#   BACKSTOP  when the park cannot establish supervision, return the shared
#             turn-end guard's repair instruction as a bounded continue follow-up.
#
# EXIT CONTRACT:
# Antigravity CLI expects exit status 0 and a JSON object on stdout:
#   {"decision": "allow"}              - allow the agent to stop normally.
#   {"decision": "continue", "reason"} - re-enter the loop with system message.
#
# On non-zero exit or empty output, Antigravity logs a hook failure or allows the
# agent to stop. This adapter therefore ALWAYS exits 0 and writes exactly one JSON
# object to stdout.
#
# Follow-up sources, in priority order, at most one per invocation:
#   1. an actionable watcher wake from the park;
#   2. the bounded repair instruction when supervision could not be established.
#
# LOOP BOUNDING:
# FM_AGY_TURNEND_LOOP_CEILING bounds consecutive hook-driven turns without captain
# intervention so an uncontrolled wake loop cannot run forever.
# BLOCK_BUDGET bounds consecutive repair follow-ups when the watcher fails to start.
#
# SUPERSESSION:
# A captain message or interruption typed while this hook is parked terminates or
# supersedes the parked hook. Each invocation publishes itself as the current
# park owner in state/.agy-park-owner, and an older park still running stands down
# without emitting a continue decision.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
OWNER="$STATE/.agy-park-owner"
OWNER_LOCK="$STATE/.agy-park-owner.lock"
BUDGET_FILE="$STATE/.turnend-agy-blocks"

LOOP_CEILING=${FM_AGY_TURNEND_LOOP_CEILING:-180}
BLOCK_BUDGET=${FM_AGY_TURNEND_BLOCK_BUDGET:-3}
ARM_ATTEMPTS=${FM_AGY_PARK_ATTEMPTS:-2}
POLL=${FM_AGY_PARK_POLL:-2}
LOCK_ATTEMPTS=${FM_AGY_LOCK_ATTEMPTS:-50}
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=180 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
case "$ARM_ATTEMPTS" in 1|2|3) : ;; *) ARM_ATTEMPTS=2 ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
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

# Only park when model stopped naturally. If stopped due to max_steps_exceeded, error, or cancel, allow.
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

budget_reset_if_ours() {
  lock_acquire_bounded "$OWNER_LOCK" || emit_allow
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
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
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
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

emit_repair_followup() {  # <reason> <arm-tail> <attempt>
  local reason=$1 arm_tail=$2 attempt_count=$3 prior count body encoded response
  park_still_ours || emit_allow
  budget_read
  [ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ] || emit_allow
  prior=$BUDGET_COUNT
  count=$((prior + 1))

  body="TURN WOULD END BLIND - supervision is off. The hook-owned watcher park could not establish a live cycle after $attempt_count bounded attempts (nag $count of $BLOCK_BUDGET).
$arm_tail

$reason"
  fm_operational_input_encode turn-end-guard "$body" encoded || emit_allow
  response=$(jq -n --arg m "$encoded" '{decision:"continue",reason:$m}' 2>/dev/null) || emit_allow

  lock_acquire_bounded "$OWNER_LOCK" || emit_allow
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
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

# --- Herdr supervisor bridge -------------------------------------------------
fm_herdr_primary_pane() {
  command -v herdr >/dev/null 2>&1 || return 1
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s\n' "$HERDR_PANE_ID"
    return 0
  fi
  herdr status >/dev/null 2>&1 || return 1
  herdr pane list 2>/dev/null | jq -r --arg cid "$SESSION_ID" --arg cwd "$FM_HOME" '
    .result.panes[] | select((.agent_session.value == $cid) or (.cwd == $cwd and .foreground_cwd == $cwd)) | .pane_id
  ' 2>/dev/null | head -1
}

ensure_herdr_bridge() {
  local pane=$1 pid monitor_was_on=0
  if [ -f "$STATE/.herdr-bridge.pid" ]; then
    pid=$(cat "$STATE/.herdr-bridge.pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) rm -f "$STATE/.herdr-bridge.pid" ;;
      *)
        if kill -0 "$pid" 2>/dev/null; then
          return 0
        fi
        rm -f "$STATE/.herdr-bridge.pid"
        ;;
    esac
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "$SCRIPT_DIR/fm-watch-herdr-bridge.sh" --pane "$pane" --session "$SESSION_ID" --owner "$OWNER_ID" >/dev/null 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  printf '%s\n' "$pid" > "$STATE/.herdr-bridge.pid"
}

kill_herdr_bridge() {
  local pid
  [ -f "$STATE/.herdr-bridge.pid" ] || return 0
  pid=$(cat "$STATE/.herdr-bridge.pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) kill "$pid" 2>/dev/null || true ;;
  esac
  rm -f "$STATE/.herdr-bridge.pid" "$STATE/.herdr-bridge.lock"
}

park_captain_input_pending() {
  local pane
  pane=$(fm_herdr_primary_pane) || return 1
  [ -n "$pane" ] || return 1
  herdr pane read "$pane" 2>/dev/null | tail -10 | grep -Eq 'Press up to edit queued messages|▸ '
}

# --- park ownership ----------------------------------------------------------
claim_park() {
  local seq tmp
  lock_acquire_bounded "$OWNER_LOCK" || return 1
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  PARK_SEQ=$((seq + 1))
  tmp="$OWNER.tmp.${BASHPID:-$$}"
  if ! printf 'seq=%s pid=%s updated_at=%s\n' "$PARK_SEQ" "${BASHPID:-$$}" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$OWNER" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$OWNER_LOCK"
  return 0
}

park_still_ours() {
  local seq
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  [ "$seq" = "$PARK_SEQ" ]
}

current_session_still_ours() {
  local owner
  owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner" = "$OWNER_ID" ] || return 1
  fm_session_lock_owned_by_self "$STATE"
}

# Only the lock-owning session may arm or wake.
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in ''|*[!0-9]*) emit_allow ;; esac
  fm_harness_pid_alive "$LOCK_PID" && emit_allow
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || emit_allow
  fm_session_lock_owned_by_self "$STATE" || emit_allow
fi

OWNER_ID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$OWNER_ID" in ''|*[!0-9]*) emit_allow ;; esac

PARK_SEQ=
claim_park || emit_allow

# Inner loop ceiling.
if [ "$LOOP_COUNT" -ge "$LOOP_CEILING" ]; then
  [ "$LOOP_COUNT" -eq "$LOOP_CEILING" ] || emit_allow
  fm_supervision_needed "$STATE" "$GRACE" || emit_allow
  emit_continue turn-end-guard "FIRSTMATE SUPERVISION CEILING REACHED - this session has taken $LOOP_COUNT consecutive hook-driven turns without a captain message, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically at the next turn end after the captain's next message."
fi

# Away mode owns the watcher and its own triage; never park and never continue.
if [ -e "$STATE/.afk" ]; then
  kill_herdr_bridge
  emit_allow
fi

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  emit_allow
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

# Antigravity CLI park requires active in-flight work, pending wakes, or active Relay watch.
# Background checks (e.g. contributions poll, PR merge polls) and PR-registered idle tasks
# do not lock an interactive session behind a blocking Stop hook.
if [ -s "$STATE/.wake-queue" ]; then
  : # Queued wake pending: must not bypass
elif { [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || ! fm_has_active_tasks "$STATE"; } && [ ! -f "$STATE/x-watch.check.sh" ]; then
  kill_herdr_bridge
  budget_reset_if_ours
  emit_allow
fi

# When running inside Herdr, the detached supervisor bridge owns autonomous prompt
# injection on wake, allowing the interactive session to release the prompt to '>'
# immediately (<20ms) instead of blocking behind a 60-second Stop hook.
HERDR_PANE=$(fm_herdr_primary_pane)
if [ -n "$HERDR_PANE" ] && [ ! -s "$STATE/.wake-queue" ]; then
  ensure_herdr_bridge "$HERDR_PANE"
  budget_reset_if_ours
  emit_allow
fi

# X mode cadence: an opted-in home polls Relay at its generated cadence.
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- the park ----------------------------------------------------------------
ARM_OUT=
ARM_PID=
ACTIONABLE=0
HEALTHY=0
STAND_DOWN=0

# Never leave an arm child or its capture file behind.
trap '[ -n "$ARM_PID" ] && kill "$ARM_PID" 2>/dev/null; [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null; :' EXIT INT TERM HUP

attempt=0
while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
  current_session_still_ours || emit_allow
  attempt=$((attempt + 1))
  ARM_OUT=$(mktemp "$STATE/.agy-park-output.XXXXXX") || ARM_OUT=
  if [ -n "$ARM_OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  while kill -0 "$ARM_PID" 2>/dev/null; do
    if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ] || park_captain_input_pending; then
      STAND_DOWN=1
      break
    fi
    sleep "$POLL"
  done
  if [ "$STAND_DOWN" -eq 1 ]; then
    kill "$ARM_PID" 2>/dev/null
    ARM_PID=
    emit_allow
  fi
  wait "$ARM_PID" 2>/dev/null || true
  ARM_PID=

  # Away mode may have been entered while parked: the daemon owns triage now.
  [ -e "$STATE/.afk" ] && emit_allow

  ACTIONABLE=0
  if [ -n "$ARM_OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$ARM_OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating inside the shared grace window.
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
  [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
  ARM_OUT=
done

if [ "$ACTIONABLE" -eq 1 ]; then
  WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
  emit_continue watcher "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake." reset-budget
fi

# The need may have vanished while parked.
if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  emit_allow
fi
if [ -s "$STATE/.wake-queue" ]; then
  : # Queued wake pending: must not bypass
elif { [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || ! fm_has_active_tasks "$STATE"; } && [ ! -f "$STATE/x-watch.check.sh" ]; then
  budget_reset_if_ours
  emit_allow
fi

# A verified live cycle with a fresh beacon is positive recovery.
if [ "$HEALTHY" -eq 1 ]; then
  budget_reset_if_ours
  emit_allow
fi

# The park could not establish supervision. Query shared turn-end guard.
GUARD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-agy.XXXXXX") || emit_allow
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --agy 2>"$GUARD_ERR"
GUARD_RC=$?
REASON=$(cat "$GUARD_ERR" 2>/dev/null || true)
rm -f "$GUARD_ERR" 2>/dev/null || true
[ "$GUARD_RC" -eq 2 ] || emit_allow

[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
ARM_TAIL=
[ -n "$ARM_OUT" ] && ARM_TAIL=$(grep -E '^watcher:' "$ARM_OUT" 2>/dev/null | head -4)
emit_repair_followup "$REASON" "$ARM_TAIL" "$attempt"
