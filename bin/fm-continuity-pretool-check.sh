#!/usr/bin/env bash
# Claude primary watcher-continuity PreToolUse gate.
#
# This hook is deliberately narrow. It denies only an executed bin/fm-*.sh fleet
# command other than bin/fm-wake-drain.sh, bin/fm-watch-arm.sh, or the
# independently fail-closed bin/fm-teardown.sh, and only when the active primary
# home has task metadata in flight, no identity-matched live watcher holds the
# home lock, and the missing watcher is unexplained. Ordinary shell commands,
# recovery commands, healthy supervision, the recorded post-wake gap, fleet-idle
# homes, and child worktrees are always allowed.
#
# The watcher is one-shot and its arm exit is the wake notification, so the home
# is deliberately unwatched while Claude handles that wake. A recent actionable
# owner row in the cycle ledger explains this gap. FM_CONTINUITY_GAP_GRACE bounds
# it so a session that never re-arms is refused again.
#
# The turn-end guard remains the final backstop, cooperating with the
# Stop-owned auto-arm in its --claude mode, and prevents a turn from ending in
# the explained gap. This gate still closes an unexplained supervision gap
# before another fleet mutation, but does not replace or weaken the Stop hooks.
#
# Input is Claude PreToolUse JSON on stdin. Tests may pass --command directly.
# Malformed transport, missing jq/Node, a missing classifier, or classifier
# failure all fail open. A deny writes Claude's hook decision to stderr only and
# exits 2.
set -u

COMMAND=
COMMAND_SET=0

usage() {
  cat <<'EOF'
Usage: fm-continuity-pretool-check.sh [--command <shell-command>]

Reads Claude PreToolUse JSON from stdin unless --command is supplied.
Exits 0 to allow. Exits 2 with a Claude deny object on stderr only when an
unhealthy primary tries to execute a non-recovery firstmate fleet script.

A missing watcher whose latest owner cycle delivered a wake within
FM_CONTINUITY_GAP_GRACE seconds (default 1800) is allowed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      COMMAND=$2
      COMMAND_SET=1
      shift 2
      ;;
    --command=*)
      COMMAND=${1#--command=}
      COMMAND_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$COMMAND_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  COMMAND=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
fi
[ -n "$COMMAND" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
WATCH="$SCRIPT_DIR/fm-watch.sh"
POLICY="$SCRIPT_DIR/fm-continuity-command-policy.mjs"
GAP_GRACE=${FM_CONTINUITY_GAP_GRACE:-1800}
case "$GAP_GRACE" in ''|*[!0-9]*) GAP_GRACE=1800 ;; esac

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-watch-cycle-lib.sh
. "$SCRIPT_DIR/fm-watch-cycle-lib.sh"

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_supervision_status "$STATE" "${FM_GUARD_GRACE:-300}"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
LOCK_PID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
if fm_pid_alive "$LOCK_PID" && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$LOCK_PID" "$FM_HOME"; then
  exit 0
fi

fm_cycle_close_explained "$STATE" "$GAP_GRACE" && exit 0

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0
CLASSIFICATION=$(node "$POLICY" --command "$COMMAND" --root "$FM_ROOT" 2>/dev/null) || exit 0
case "$CLASSIFICATION" in
  deny*) ;;
  *) exit 0 ;;
esac

TAB=$(printf '\t')
REST=${CLASSIFICATION#*"$TAB"}
[ -n "$REST" ] && [ "$REST" != "$CLASSIFICATION" ] || exit 0
BLOCKED_SCRIPT=${REST%%"$TAB"*}
REASON_CODE=${REST#*"$TAB"}
[ "$REASON_CODE" != "$REST" ] || REASON_CODE=""
case "$REASON_CODE" in
  unsafe-teardown)
    REASON="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; during recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: $BLOCKED_SCRIPT)"
    ;;
  *)
    REASON="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; drain wakes with bin/fm-wake-drain.sh, use fail-closed bin/fm-teardown.sh for completed tasks when needed, then end the turn so the Stop-owned auto-arm re-establishes the watcher; if the Stop auto-arm itself failed, re-arm manually with bin/fm-watch-arm.sh as a tracked Claude background task (blocked: $BLOCKED_SCRIPT)"
    ;;
esac
ESCAPED=$(printf '%s' "$REASON" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
