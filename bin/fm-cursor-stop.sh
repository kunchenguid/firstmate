#!/usr/bin/env bash
# Cursor stop-hook adapter for bin/fm-turnend-guard.sh.
#
# Cursor Hooks invoke this on agent stop. Exit 2 blocks the stop (Claude-shaped
# direct block). When Cursor already re-entered stop because of a prior block
# (loop_count / stop_hook_active), we allow the stop so the session cannot wedge.
#
# Fail open on empty stdin, missing jq, or guard allow - never wedge the primary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/fm-turnend-guard.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Normalize Cursor / Claude-shaped loop-guard fields into stop_hook_active.
NORMALIZED=$(printf '%s' "$PAYLOAD" | jq -c '
  . as $in
  | (if (.stop_hook_active == true) then true
     elif ((.loop_count // 0) | tonumber) > 0 then true
     else false end) as $active
  | ($in + {stop_hook_active: $active})
' 2>/dev/null) || exit 0

err=
rc=0
err=$(printf '%s' "$NORMALIZED" | "$GUARD" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 2 ] || exit 0

# Prefer a followup nudge when Cursor accepts followup_message on stop; still
# exit 2 so harnesses that only honor exit status also block once.
reason=$(printf '%s' "$err" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$reason" ] || reason='Tasks are in flight without a live watcher. Resume supervision with bin/fm-watch-arm.sh as its own Cursor Shell background task (block_until_ms: 0), then continue.'

jq -nc --arg msg "$reason" '{followup_message: $msg}' 2>/dev/null || true
exit 2
