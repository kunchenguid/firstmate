#!/usr/bin/env bash
# Agy Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Agy can continue the same live execution loop when a Stop hook returns a
# continue decision.
# executionNum zero may invoke the shared guard, while every later execution in
# that same loop is allowed so one Stop event can force at most one follow-up.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMITTED=0
ERR=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup_agy_turnend_guard() {
  [ -z "$ERR" ] || rm -f "$ERR"
  [ "$EMITTED" -eq 1 ] || printf '{}\n'
}
trap cleanup_agy_turnend_guard EXIT
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

EXECUTION_NUM=$(printf '%s' "$PAYLOAD" | jq -er '
  select(type == "object")
  | .executionNum
  | select(type == "number" and floor == . and . >= 0)
' 2>/dev/null) || exit 0
[ "$EXECUTION_NUM" -eq 0 ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-agy.XXXXXXXXXXXX") || exit 0
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='Tasks are in flight, but watcher supervision is not running. Repair supervision according to the session-start operating block before ending the turn.'
RESPONSE=$(jq -cn --arg reason "$REASON" '{"decision":"continue","reason":$reason}') || exit 0
[ -n "$RESPONSE" ] || exit 0
EMITTED=1
printf '%s\n' "$RESPONSE"
exit 0
