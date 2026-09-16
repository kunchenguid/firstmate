#!/usr/bin/env bash
# DSH UserPromptSubmit adapter delivering the firstmate session-start operating
# block before the first model request.
#
# DSH's SessionStart hook runs detached and its additionalContext lands AFTER
# the first request as a user-shaped message (verified 2026-09-16), which is the
# wrong tier for a session-start digest. UserPromptSubmit fires before the model
# call and its additionalContext is part of the request, so the digest rides
# that event instead. UserPromptSubmit fires on EVERY prompt, so delivery is
# gated once per session id.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

ROOT=${FM_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-session-start.sh" ] || exit 0

STATE=${FM_STATE_OVERRIDE:-$ROOT/state}
[ -d "$STATE" ] || exit 0
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
MARKER="$STATE/.dsh-sessionstart-delivered"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null || true)" = "$SESSION_ID" ]; then
  exit 0
fi
printf '%s\n' "$SESSION_ID" > "$MARKER" 2>/dev/null || exit 0

"$ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 || true

AFK=0; [ -e "$STATE/.afk" ] && AFK=1
X_MODE=0; [ -f "$ROOT/config/x-mode.env" ] && X_MODE=1
BLOCK=$("$ROOT/bin/fm-supervision-instructions.sh" --afk "$AFK" --x-mode "$X_MODE" 2>/dev/null || true)
[ -n "$BLOCK" ] || exit 0

jq -cn --arg c "$BLOCK" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
