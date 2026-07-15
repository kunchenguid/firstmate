#!/usr/bin/env bash
# Adapt Cursor's stop-hook loop_count/followup_message contract to the shared
# firstmate turn-end predicate. Fail open at the hook boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || { printf '%s\n' '{}'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' '{}'; exit 0; }

loop_count=$(printf '%s' "$payload" | jq -r '.loop_count // 0' 2>/dev/null) \
  || { printf '%s\n' '{}'; exit 0; }
case "$loop_count" in
  ''|*[!0-9]*) printf '%s\n' '{}'; exit 0 ;;
esac
[ "$loop_count" -eq 0 ] || { printf '%s\n' '{}'; exit 0; }

translated=$(printf '%s' "$payload" | jq '. + {stop_hook_active: false}' 2>/dev/null) \
  || { printf '%s\n' '{}'; exit 0; }
err=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor.XXXXXX") \
  || { printf '%s\n' '{}'; exit 0; }
if printf '%s' "$translated" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>"$err"; then
  rm -f "$err"
  printf '%s\n' '{}'
  exit 0
else
  status=$?
fi
if [ "$status" -eq 2 ]; then
  reason=$(cat "$err" 2>/dev/null || true)
  rm -f "$err"
  [ -n "$reason" ] || reason='TURN WOULD END BLIND: resume the session-start supervision protocol.'
  jq -cn --arg message "$reason" '{followup_message: $message}'
  exit 0
fi
rm -f "$err"
printf '%s\n' '{}'
exit 0
