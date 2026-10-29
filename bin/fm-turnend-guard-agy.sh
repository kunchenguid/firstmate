#!/usr/bin/env bash
# Antigravity (agy) Stop-parked primary supervision hook (.agents/hooks.json).
#
# Antigravity evaluates project-local .agents/hooks.json (Stop event) at the
# end of every agent turn and awaits the hook synchronously. Like Cursor,
# Antigravity does not expose an asynchronous background rewake channel on
# Stop, so this hook parks the turn boundary on a tracked child, modeled on
# bin/fm-turnend-guard-cursor.sh:
#   - bin/fm-watch-arm.sh, or bin/fm-supervision-host.sh park when the home
#     runs the supervision host (fm_supervision_host_enabled ... agy).
#   - The child is polled every FM_AGY_PARK_POLL seconds (default 2) and the
#     park waits on it under the 28800s hooks.json timeout, so an idle cycle
#     spends no model turn. Only when FM_AGY_PARK_TIMEOUT is set to a positive
#     number of seconds, and that total wait across every attempt passes with
#     the child still running, is the child stopped and
#     {"decision":"continue","reason":"[supervision-park] ..."} returned so the
#     next turn boundary parks again.
#   - An actionable close (a signal:/stale:/check:/heartbeat line, or a
#     supervision-host: line in host mode) resets state/.turnend-blocks and
#     returns {"decision":"continue","reason":"<wake>"} on stdout.
#   - A non-actionable close beside a verified healthy watcher, or a host that
#     stood down, ends the turn with {}.
#   - When the park cannot establish supervision after bounded attempts, the
#     shared bin/fm-turnend-guard.sh --agy owns the bounded repair nag.
#
# Guard rails before parking:
#   - Stand down in crewmate/scout linked worktrees (fm_primary_scope_matches).
#   - Pass through non-normal terminationReason values (anything non-empty
#     other than NO_TOOL_CALL) with {} without parking.
#   - Verify session-lock ownership via bin/fm-session-lock-lib.sh so a
#     read-only or foreign session never steals supervision.
#   - At executionNum == the loop ceiling (default 180, overridable via
#     FM_AGY_TURNEND_LOOP_CEILING) with supervision still needed, return one
#     loud ceiling notice; past the ceiling, pass through with {}.
#   - Record a unique claim in state/.agy-park-owner before parking and yield
#     cleanly with {} if a newer Stop hook superseded this park while waiting.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
ARM_ATTEMPTS=2

POLL=${FM_AGY_PARK_POLL:-2}
PARK_TIMEOUT=${FM_AGY_PARK_TIMEOUT:-0}
LOOP_CEILING=${FM_AGY_TURNEND_LOOP_CEILING:-180}
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$PARK_TIMEOUT" in ''|*[!0-9]*) PARK_TIMEOUT=0 ;; esac
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=180 ;; esac

allow_stop() {
  printf '{}\n'
  exit 0
}

continue_turn() {  # <reason>
  jq -cn --arg r "$1" '{decision:"continue",reason:$r}'
  exit 0
}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow_stop
command -v jq >/dev/null 2>&1 || allow_stop

fm_primary_scope_matches "$FM_ROOT" "$STATE" || allow_stop

TERM_REASON=$(printf '%s' "$PAYLOAD" | jq -r '.terminationReason // empty' 2>/dev/null || true)
if [ -n "$TERM_REASON" ] && [ "$TERM_REASON" != "NO_TOOL_CALL" ]; then
  allow_stop
fi

EXEC_NUM=$(printf '%s' "$PAYLOAD" | jq -r 'if (.executionNum | type) == "number" then (.executionNum | floor | tostring) else "" end' 2>/dev/null || true)

if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$LOCK_PID" || allow_stop
  fm_harness_pid_alive "$LOCK_PID" && allow_stop
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || allow_stop
  fm_session_lock_owned_by_self "$STATE" || allow_stop
fi

# Away mode owns the watcher and its own triage; never park and never wake.
[ -e "$STATE/.afk" ] && allow_stop

# The ceiling bounds hook-driven turns. Reaching it while supervision is still
# needed is told once, loudly, instead of supervision going quiet unannounced.
if [ -n "$EXEC_NUM" ] && [ "$EXEC_NUM" -ge "$LOOP_CEILING" ]; then
  [ "$EXEC_NUM" -eq "$LOOP_CEILING" ] || allow_stop
  fm_supervision_needed "$STATE" "$GRACE" || allow_stop
  continue_turn "FIRSTMATE SUPERVISION FOLLOW-UP CEILING REACHED - this session has taken $EXEC_NUM consecutive hook-driven turns, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically at the next turn end after the captain's next message."
fi

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  allow_stop
fi

mkdir -p "$STATE" 2>/dev/null || true
PARK_OWNER_FILE="$STATE/.agy-park-owner"
PARK_OWNER="$$:$(date +%s):${RANDOM:-0}"
printf '%s\n' "$PARK_OWNER" > "$PARK_OWNER_FILE"

park_still_ours() {
  [ "$(cat "$PARK_OWNER_FILE" 2>/dev/null || true)" = "$PARK_OWNER" ]
}

ARM_OUT=
ARM_PID=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
if fm_supervision_host_enabled "$CONFIG" agy; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi

# Never leave a park child or its capture file behind, on any exit path.
trap '[ -n "$ARM_PID" ] && kill "$ARM_PID" 2>/dev/null; [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null; :' EXIT

waited=0
attempt=0
while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
  [ "$PARK_TIMEOUT" -eq 0 ] || [ "$waited" -lt "$PARK_TIMEOUT" ] || break
  attempt=$((attempt + 1))
  ARM_OUT=$(mktemp "$STATE/.agy-park-output.XXXXXX") || { ARM_OUT=; break; }
  if [ "$HOST_MODE" -eq 1 ]; then
    FM_SUPERVISION_HOST_PRIMARY=agy "$SCRIPT_DIR/fm-supervision-host.sh" park >"$ARM_OUT" 2>&1 &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
  fi
  ARM_PID=$!
  while kill -0 "$ARM_PID" 2>/dev/null; do
    # Stand down when a newer Stop claimed the baton, the session lock moved,
    # or away mode started and its daemon now owns the watcher.
    if ! park_still_ours || ! fm_session_lock_owned_by_self "$STATE" || [ -e "$STATE/.afk" ]; then
      allow_stop
    fi
    if [ "$PARK_TIMEOUT" -gt 0 ] && [ "$waited" -ge "$PARK_TIMEOUT" ]; then
      kill "$ARM_PID" 2>/dev/null
      ARM_PID=
      continue_turn "[supervision-park] No actionable wake arrived within ${PARK_TIMEOUT}s while supervision is still needed. End your turn briefly so the Antigravity Stop hook can re-park on the next turn boundary."
    fi
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  HOST_RC=0
  wait "$ARM_PID" 2>/dev/null || HOST_RC=$?
  ARM_PID=

  park_still_ours || allow_stop
  [ -e "$STATE/.afk" ] && allow_stop

  if grep -Eq "$ACTIONABLE_RE" "$ARM_OUT" 2>/dev/null; then
    ACTIONABLE=1
    break
  fi

  if [ "$HOST_MODE" -eq 1 ]; then
    # The host stood down because this session no longer owns supervision.
    grep -q '^supervision-host stood down:' "$ARM_OUT" 2>/dev/null && allow_stop
    # A host that died without a close is retried so the next host can stop
    # what it left and own a fresh cycle.
    if [ "$HOST_RC" -gt 128 ] || [ ! -s "$ARM_OUT" ]; then
      rm -f "$ARM_OUT" 2>/dev/null
      ARM_OUT=
      continue
    fi
  fi

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating inside the shared grace window.
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
  rm -f "$ARM_OUT" 2>/dev/null
  ARM_OUT=
done

# The need may have vanished while parked: nothing left to supervise.
if ! fm_supervision_needed "$STATE" "$GRACE"; then
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  allow_stop
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  if [ "$HOST_MODE" -eq 1 ]; then
    WAKE=$(awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$ARM_OUT" 2>/dev/null)
  else
    WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
  fi
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  continue_turn "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake."
fi

if [ "$HEALTHY" -eq 1 ]; then
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  allow_stop
fi

# The park could not establish supervision: the shared guard owns the bounded
# repair nag and its {} fail-open.
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --agy
exit 0
