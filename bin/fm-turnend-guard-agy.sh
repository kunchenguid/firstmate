#!/usr/bin/env bash
# AGY Stop hook adapter: turn-end guard for an Antigravity primary session.
#
# Registered in tracked .agents/hooks.json for AGY's `Stop` step. It intercepts
# turn termination in a genuine primary session and invokes the push-based
# turn-end guard (bin/fm-turnend-guard.sh) to verify watcher health.
#
# AGY evaluates turn completion by inspecting stdout JSON:
#   {"decision": "continue", "reason": "<instructions>"} forces a continuation turn.
#   {"decision": "allow"} permits turn termination.
#
# Loop guard: AGY provides `executionNum` in its Stop hook payload, counting how
# many Stop attempts occurred within the current turn cycle. If executionNum >=
# FM_AGY_TURNEND_BLOCK_BUDGET (default 1), this adapter allows the stop to avoid
# infinite continuation loops.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

allow_stop() {
  printf '{"decision": "allow"}\n'
  exit 0
}

continue_turn() {  # <reason>
  local reason=$1
  command -v jq >/dev/null 2>&1 || {
    printf '{"decision": "continue", "reason": "supervision is off: repair watcher before ending turn"}\n'
    exit 0
  }
  jq -n --arg r "$reason" '{"decision": "continue", "reason": $r}'
  exit 0
}

# Scope precisely to primary checkout (main home or marked secondmate home).
fm_primary_scope_matches "$FM_ROOT" "$STATE" || allow_stop

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow_stop
command -v jq >/dev/null 2>&1 || allow_stop

EXECUTION_NUM=$(printf '%s' "$PAYLOAD" | jq -r '.executionNum // 0' 2>/dev/null || echo 0)
case "$EXECUTION_NUM" in ''|*[!0-9]*) EXECUTION_NUM=0 ;; esac
BLOCK_BUDGET=${FM_AGY_TURNEND_BLOCK_BUDGET:-1}
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=1 ;; esac

if [ "$EXECUTION_NUM" -ge "$BLOCK_BUDGET" ]; then
  allow_stop
fi

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# If another verified live session holds the lock, this session is read-only
# and cannot repair supervision without stealing ownership.
if fm_session_lock_foreign_owner_live "$STATE"; then
  allow_stop
fi

GUARD_OUT=$(printf '{"stop_hook_active": false}\n' | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>&1)
GUARD_RC=$?

if [ "$GUARD_RC" -eq 2 ]; then
  continue_turn "$GUARD_OUT"
fi

allow_stop
