#!/usr/bin/env bash
# Codex Stop-owned idle continuity for process-event reconciliation.
#
# Codex Stop hooks are synchronous and asynchronous command hooks are not
# available (codex-cli 0.154.0, developers.openai.com/codex/hooks). Holding
# the watcher inside the hook would keep the turn in progress. This script
# therefore starts one detached supervisor only on the allowing stop
# (stop_hook_active true), after the one forced continuation, and then
# forwards the original payload to bin/fm-turnend-guard.sh.
#
# The supervisor is not a shell job of the hook. setsid --fork returns as
# soon as the new session exists, and that session foregrounds
# bin/fm-watch-arm.sh. While the recorded Codex process lives, each
# actionable arm close is queued back into the same thread with
# `codex queue`. FM_CODEX_IDLE_QUEUE, when set, receives that text on stdin
# instead. FM_CODEX_IDLE_OWNER_PID overrides the Codex ancestor walk.
#
# An idle home, away mode, a child worktree, or a stop that is still the
# first one in the turn does not start a supervisor. A live supervisor is
# left in place. This script never prints on the spawn path: the guard's
# stdout and stderr are the hook output.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.codex-idle-continuity.lock"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"

codex_ancestor() {
  local pid comm
  if [ -n "${FM_CODEX_IDLE_OWNER_PID:-}" ]; then
    printf '%s\n' "$FM_CODEX_IDLE_OWNER_PID"
    return 0
  fi
  pid=$PPID
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    comm=$(ps -p "$pid" -o comm= 2>/dev/null | awk '{print $1}') || comm=
    case "$comm" in
      codex) printf '%s\n' "$pid"; return 0 ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]') || pid=
  done
  return 1
}

supervisor_live() {
  local pid
  [ -f "$LOCK/pid" ] || return 1
  IFS= read -r pid < "$LOCK/pid" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

reclaim_stale_lock() {
  supervisor_live && return 1
  rm -rf "$LOCK"
  return 0
}

ensure_supervisor() {  # <session-id>
  local owner session=$1
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  [ -e "$STATE/.afk" ] && return 0
  fm_supervision_needed "$STATE" || return 0
  owner=$(codex_ancestor) || return 0
  if supervisor_live; then
    return 0
  fi
  reclaim_stale_lock || true
  mkdir -p "$STATE"
  mkdir "$LOCK" 2>/dev/null || return 0
  printf '%s\n' "$owner" > "$LOCK/owner"
  printf '%s\n' "$session" > "$LOCK/session"
  if ! setsid --fork "$0" --supervise; then
    rm -rf "$LOCK"
    return 0
  fi
}

queue_text() {
  local text=$1 session
  [ -n "$text" ] || return 0
  if [ -n "${FM_CODEX_IDLE_QUEUE:-}" ]; then
    printf '%s\n' "$text" | "$FM_CODEX_IDLE_QUEUE"
    return 0
  fi
  IFS= read -r session < "$LOCK/session" || session=
  [ -n "$session" ] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  codex queue --thread "$session" --message "$text" >/dev/null 2>&1 || true
}

actionable_text() {
  awk '/^(signal:|stale:|check:|heartbeat(:|$))/'
}

supervise() {
  local owner arm_pid text fails=0
  IFS= read -r owner < "$LOCK/owner" || exit 0
  case "$owner" in ''|*[!0-9]*) exit 0 ;; esac
  printf '%s\n' "$$" > "$LOCK/pid"
  trap '"$ARM" --stop >/dev/null 2>&1 || true; rm -rf "$LOCK"; exit 0' TERM INT
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  while kill -0 "$owner" 2>/dev/null; do
    [ -e "$STATE/.afk" ] && break
    fm_supervision_needed "$STATE" || break
    "$ARM" >"$LOCK/arm.out" 2>&1 &
    arm_pid=$!
    while kill -0 "$arm_pid" 2>/dev/null; do
      if ! kill -0 "$owner" 2>/dev/null; then
        "$ARM" --stop >/dev/null 2>&1 || true
        kill "$arm_pid" 2>/dev/null || true
        break
      fi
      sleep 0.5
    done
    wait "$arm_pid" || true
    text=$(actionable_text < "$LOCK/arm.out" || true)
    if [ -n "$text" ]; then
      fails=0
      queue_text "$text" || true
      continue
    fi
    fails=$((fails + 1))
    [ "$fails" -lt 3 ] || break
    sleep 1
  done
  "$ARM" --stop >/dev/null 2>&1 || true
  rm -rf "$LOCK"
}

if [ "${1:-}" = "--supervise" ]; then
  supervise
  exit 0
fi

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
export FM_ROOT FM_HOME STATE FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$FM_ROOT}"
if command -v jq >/dev/null 2>&1; then
  stop_active=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" and .stop_hook_active == true then "true" else "false" end' 2>/dev/null || printf 'false')
  session=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" then (.session_id // "") else "" end' 2>/dev/null || printf '')
  if [ "$stop_active" = "true" ]; then
    ensure_supervisor "$session"
  fi
fi
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"
exit $?
