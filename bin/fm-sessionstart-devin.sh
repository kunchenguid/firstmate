#!/usr/bin/env bash
# Devin session-open adapter: the RUN tier transport for Devin CLI.
#
# Registered in tracked .devin/hooks.v1.json for Devin's SessionStart event.
# It is a thin transport around bin/fm-sessionstart-run.sh, which remains the
# single owner of source routing, eligibility, and the digest itself.
#
# Devin injects a hook's hookSpecificOutput.additionalContext string straight
# into model context, so the digest lands before the first turn and the helm
# is taken without model discretion. The payload's own `source` field
# (startup|resume|...) is forwarded to the run wrapper as --source.
# Verified live on devin 3000.11.3.
#
# Every path exits 0 and prints either nothing or one JSON object. A failed
# session start must reach the agent as digest text it can act on, never as a
# refusal to open the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE=
PAYLOAD=$(cat 2>/dev/null || true)
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  SOURCE=$(printf '%s' "$PAYLOAD" | jq -r '.source // empty' 2>/dev/null || true)
fi

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "$SOURCE" </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -n --arg c "$DIGEST" \
  '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$c}}' 2>/dev/null || true
exit 0
