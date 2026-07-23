#!/usr/bin/env bash
# Cursor stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Cursor stop hooks are passive for exit status: the useful lever is returning
# {"followup_message":"..."} so Cursor auto-submits one follow-up user message.
# This adapter still uses the shared primary-scoped predicate in
# fm-turnend-guard.sh. When that predicate says the primary would end blind,
# emit one followup_message. loop_count (and hooks.json loop_limit: 1) is the
# loop guard - never force a second automatic follow-up in the same stop chain.
#
# Usage: wired from .cursor/hooks.json stop; reads Cursor stop JSON on stdin,
# prints Cursor stop JSON on stdout.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || { printf '%s\n' '{}'; exit 0; }

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || {
  printf '%s\n' '{}'
  exit 0
}
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)" || {
  printf '%s\n' '{}'
  exit 0
}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || { printf '%s\n' '{}'; exit 0; }

command -v jq >/dev/null 2>&1 || { printf '%s\n' '{}'; exit 0; }

LOOP_COUNT=$(printf '%s' "$PAYLOAD" | jq -r '.loop_count // 0' 2>/dev/null) || LOOP_COUNT=0
case "$LOOP_COUNT" in
  ''|*[!0-9]*) LOOP_COUNT=0 ;;
esac
# Already forced one follow-up in this stop chain - allow the stop.
if [ "$LOOP_COUNT" -gt 0 ]; then
  printf '%s\n' '{}'
  exit 0
fi

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor.XXXXXX") || { printf '%s\n' '{}'; exit 0; }
trap 'rm -f "$ERR"' EXIT

# Cursor does not set stop_hook_active; feed a payload the shared guard accepts.
printf '%s' '{"stop_hook_active":false}' | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || { printf '%s\n' '{}'; exit 0; }

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
    || printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//' | sed 's/^/"/;s/$/"/'
}

ESCAPED=$(json_escape "$REASON")
printf '{"followup_message":%s}\n' "$ESCAPED"
exit 0
