#!/usr/bin/env bash
# DSH Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# DSH delivers the Stop payload as JSON on stdin and honours exit 2 with stderr
# as the continuation reason. It reports stop_hook_active=false on every Stop
# and offers no async re-wake hook, so the shared guard's --dsh mode owns the
# bounded re-block budget instead of trusting that field. Unreadable input,
# absent jq, or an unresolvable root all fail open, matching every other
# harness hook in this repo.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

ROOT=${FM_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" --dsh
RC=$?
case "$RC" in
  0|2) exit "$RC" ;;
  *) exit 0 ;;
esac
