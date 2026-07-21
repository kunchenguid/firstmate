#!/usr/bin/env bash
# Hermes on_session_end adapter for the Firstmate PRIMARY turn-end guard.
#
# Hermes v0.19.0 shell hooks are passive: their exit status does not block the
# turn. This adapter runs the shared primary predicate and, when it returns 2,
# forces one same-session follow-up with `hermes --resume <session-id> -z ...`.
# HERMES_TURNEND_GUARD_ACTIVE bounds the adapter to one follow-up per turn.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ -z "${HERMES_TURNEND_GUARD_ACTIVE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v hermes >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-hermes.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

HERMES_TURNEND_GUARD_ACTIVE=1 \
  hermes --resume "$SESSION_ID" --yolo --accept-hooks \
    -z "TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.

$REASON" >/dev/null 2>&1 || true
exit 0
