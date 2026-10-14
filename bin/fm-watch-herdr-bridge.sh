#!/usr/bin/env bash
# Herdr supervisor bridge for Firstmate under Antigravity CLI (agy).
#
# When Antigravity CLI runs as Firstmate inside Herdr, the Stop hook does not
# need to block the interactive agent loop with a 60-second synchronous park.
# Instead, this bridge process runs in the background. It monitors for actionable
# wakes via bin/fm-watch-arm.sh, and when a wake occurs (e.g. crewmate completes,
# check triggers, PR merges), it injects the wake directly into Firstmate's
# pane using `herdr agent prompt <pane_id> "<wake_text>"`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
PID_FILE="$STATE/.herdr-bridge.pid"
LOCK_FILE="$STATE/.herdr-bridge.lock"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

SESSION_ID=
OWNER_ID=
PANE_ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pane)
      [ "$#" -gt 1 ] || { echo "error: --pane requires a value" >&2; exit 2; }
      PANE_ID=$2
      shift 2
      ;;
    --session)
      [ "$#" -gt 1 ] || { echo "error: --session requires a value" >&2; exit 2; }
      SESSION_ID=$2
      shift 2
      ;;
    --owner)
      [ "$#" -gt 1 ] || { echo "error: --owner requires a value" >&2; exit 2; }
      OWNER_ID=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[ -n "$PANE_ID" ] || exit 1
# shellcheck disable=SC2034 # May be inspected by session validation probes
SESSION_IDENT="$SESSION_ID"
command -v herdr >/dev/null 2>&1 || exit 1

if [ -z "${OWNER_ID:-}" ]; then
  OWNER_ID=$(cat "$STATE/.lock" 2>/dev/null || true)
fi

# Acquire singleton lock
if ! fm_lock_try_acquire "$LOCK_FILE"; then
  exit 0
fi

ARM_PID=
cleanup() {
  [ -n "${ARM_PID:-}" ] && kill "$ARM_PID" 2>/dev/null || true
  rm -f "$PID_FILE"
  fm_lock_release "$LOCK_FILE"
}
trap cleanup EXIT INT TERM HUP

printf '%s\n' "$$" > "$PID_FILE"

is_session_owner_live() {
  local lock_pid
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "${OWNER_ID:-}" ]; then
    [ "$lock_pid" = "$OWNER_ID" ] || return 1
  fi
  fm_harness_pid_alive "$lock_pid" || return 1
}

is_captain_input_pending() {
  local pane=$1
  herdr pane read "$pane" 2>/dev/null | tail -10 | grep -Eq 'Press up to edit queued messages|▸ '
}

while :; do
  # Check session lock
  if ! is_session_owner_live; then
    break
  fi

  # Check away mode
  if [ -e "$STATE/.afk" ]; then
    break
  fi

  # Check if supervision is needed
  if ! fm_supervision_needed "$STATE" "$GRACE" && [ ! -s "$STATE/.wake-queue" ]; then
    break
  fi

  # Run watcher arm
  ARM_OUT=$(mktemp "$STATE/.herdr-bridge-arm.XXXXXX" 2>/dev/null) || ARM_OUT=
  if [ -n "$ARM_OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!

  while kill -0 "$ARM_PID" 2>/dev/null; do
    if ! is_session_owner_live || [ -e "$STATE/.afk" ]; then
      kill "$ARM_PID" 2>/dev/null
      break 2
    fi
    sleep 0.5
  done
  wait "$ARM_PID" 2>/dev/null || true
  ARM_PID=

  ACTIONABLE=0
  if [ -n "$ARM_OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$ARM_OUT" 2>/dev/null && ACTIONABLE=1
  fi

  if [ "$ACTIONABLE" -eq 1 ]; then
    WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
    rm -f "$ARM_OUT" 2>/dev/null
    ARM_OUT=

    PROMPT="firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake."

    # Delivery loop: wait until agent is idle and no composer input pending
    delivery_attempts=0
    while [ "$delivery_attempts" -lt 30 ]; do
      delivery_attempts=$((delivery_attempts + 1))
      if ! is_session_owner_live || [ -e "$STATE/.afk" ]; then
        break 2
      fi

      agent_status=$(herdr agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
      case "$agent_status" in
        idle|done|"")
          if ! is_captain_input_pending "$PANE_ID"; then
            if herdr agent prompt "$PANE_ID" "$PROMPT" 2>/dev/null; then
              break
            fi
          fi
          ;;
        working)
          # Agent is already working on something; wake stays queued in .wake-queue
          break
          ;;
      esac
      sleep 0.5
    done

    sleep 1
  else
    [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
    ARM_OUT=
    sleep 1
  fi
done
