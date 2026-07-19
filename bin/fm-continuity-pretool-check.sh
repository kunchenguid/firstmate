#!/usr/bin/env bash
# Claude primary watcher-continuity PreToolUse gate.
#
# This hook is deliberately narrow. It denies only an executed bin/fm-*.sh fleet
# command other than bin/fm-wake-drain.sh or bin/fm-watch-arm.sh, and only when
# the active primary home has task metadata in flight but no identity-matched
# live watcher holds the home lock. Ordinary shell commands, recovery commands,
# healthy supervision, fleet-idle homes, and child worktrees are always allowed.
#
# The existing turn-end guard remains the unchanged final backstop. This gate
# closes the long-turn gap before another fleet mutation, but does not replace or
# weaken the Stop hook.
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

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_supervision_status "$STATE" "${FM_GUARD_GRACE:-300}"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
LOCK_PID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
if fm_pid_alive "$LOCK_PID" && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$LOCK_PID" "$FM_HOME"; then
  exit 0
fi

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0
CLASSIFICATION=$(node "$POLICY" --command "$COMMAND" --root "$FM_ROOT" 2>/dev/null) || exit 0
case "$CLASSIFICATION" in
  deny*) ;;
  *) exit 0 ;;
esac

TAB=$(printf '\t')
BLOCKED_SCRIPT=${CLASSIFICATION#*"$TAB"}
[ -n "$BLOCKED_SCRIPT" ] && [ "$BLOCKED_SCRIPT" != "$CLASSIFICATION" ] || exit 0
REASON="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; run bin/fm-wake-drain.sh, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: $BLOCKED_SCRIPT)"
ESCAPED=$(printf '%s' "$REASON" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
