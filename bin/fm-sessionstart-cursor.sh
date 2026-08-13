#!/usr/bin/env bash
# Cursor session-open adapter: the RUN tier transport for Cursor Agent CLI.
#
# Registered in tracked .cursor/hooks.json for Cursor's `sessionStart` and
# `preCompact` steps. It is a thin transport around bin/fm-sessionstart-run.sh,
# which remains the single owner of source routing, eligibility, and the digest
# itself; this script only decides where that digest is DELIVERED, because
# Cursor's two session-open steps have different capabilities.
#
#   sessionStart  Cursor injects a hook's `additional_context` string straight
#                 into model context, so the digest lands before the first turn
#                 and the helm is taken without model discretion. Verified live
#                 on 2026.08.11-e8db854.
#   preCompact    Cursor's response type for this step carries only
#                 `user_message` (PreCompactRequestResponse, index.js @ 4460902)
#                 and preCompact is absent from the additional_context step set
#                 (index.js @ 4814884). It therefore CANNOT inject context.
#                 The re-emit digest is staged in state/.cursor-pending-context
#                 instead, and bin/fm-turnend-guard-cursor.sh delivers it as one
#                 session-start-typed follow-up at the first turn boundary after
#                 the compaction.
#
# Usage: fm-sessionstart-cursor.sh --source <source>
#   Cursor's payload has no Claude-style `source` field, so the registration
#   supplies it. The delivery route is read from the payload's own
#   `hook_event_name`, defaulting to context injection.
#
# Every path exits 0 and prints either nothing or one JSON object. Cursor blocks
# session initialization when a sessionStart hook exits 2 (index.js @ 4823085
# maps it to `{continue:false}`), so a failed session start must reach the agent
# as digest text it can act on, never as a refusal to open the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PENDING_CONTEXT="$STATE/.cursor-pending-context"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

PAYLOAD=$(cat 2>/dev/null || true)
EVENT=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
fi

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "$SOURCE" </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0

if [ "$EVENT" = preCompact ]; then
  # Staged, not injected. A stale stage from an interrupted compaction is
  # replaced rather than appended, so the session never receives two digests.
  [ -d "$STATE" ] || exit 0
  TMP="$PENDING_CONTEXT.tmp.$$"
  printf '%s' "$DIGEST" > "$TMP" 2>/dev/null && mv -f "$TMP" "$PENDING_CONTEXT" 2>/dev/null
  rm -f "$TMP" 2>/dev/null || true
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
jq -n --arg c "$DIGEST" '{additional_context:$c}' 2>/dev/null || true
exit 0
