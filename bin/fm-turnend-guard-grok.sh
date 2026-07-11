#!/usr/bin/env bash
# Grok Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Grok Stop hooks are passive: exit 2 does not block or feed stderr back to the
# model. This adapter still uses the shared primary-scoped predicate in
# fm-turnend-guard.sh. When that predicate says the primary would end blind, the
# adapter forces one same-session follow-up by running `grok --resume <session>`
# with a guard instruction. GROK_TURNEND_GUARD_ACTIVE is the loop guard: the
# nested turn's own Stop hook exits without spawning another nested turn.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

[ -n "${GROK_TURNEND_GUARD_ACTIVE:-}" ] && exit 0

ROOT=${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.sessionId // empty' 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-grok.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn'

GROK_TURNEND_GUARD_ACTIVE=1 \
  GROK_HOME="${GROK_HOME:-$HOME/.grok}" \
  grok --resume "$SESSION_ID" \
    --cwd "$ROOT" \
    --output-format plain \
    -p "TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.

$REASON" >/dev/null 2>&1 || true
