#!/usr/bin/env bash
# Cursor preCompact adapter: stage refreshed context for the next stop hook.
#
# Cursor accepts only `user_message` from preCompact and does not inject that
# response into model context. Run the ordinary compact-source session-start
# path now, persist its output, and let fm-turnend-guard-cursor.sh deliver it as
# a typed follow-up at the next stop boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PENDING="$STATE/.cursor-pending-context"

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source compact </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
mkdir -p "$STATE" 2>/dev/null || exit 0
TMP="$PENDING.tmp.${BASHPID:-$$}"
trap 'rm -f "$TMP" 2>/dev/null || true' EXIT
printf '%s\n' "$DIGEST" > "$TMP" 2>/dev/null || exit 0
mv -f "$TMP" "$PENDING" 2>/dev/null || exit 0
exit 0
