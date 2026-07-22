#!/usr/bin/env bash
# Hermes on_session_end adapter for the Firstmate PRIMARY turn-end guard.
#
# Hermes v0.19.0 shell hooks are passive: their exit status does not block the
# turn. This adapter runs the shared primary predicate and, when it returns 2,
# forces one independent follow-up with `hermes -z ...`.
# HERMES_TURNEND_GUARD_ACTIVE bounds the adapter to one follow-up per turn.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ -z "${HERMES_TURNEND_GUARD_ACTIVE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v hermes >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$PAYLOAD" | jq -r '.interrupted // false' 2>/dev/null)" != true ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-hermes.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

FOLLOWUP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-turnend-hermes-home.XXXXXX") || exit 0
trap 'rm -f "$ERR"; rm -rf "$FOLLOWUP_ROOT"' EXIT
HERMES_SOURCE_HOME="${HERMES_HOME:-$HOME/.hermes}" \
  "$SCRIPT_DIR/fm-hermes-home.sh" task "$FOLLOWUP_ROOT/home" "$FOLLOWUP_ROOT/followup.turn-ended" >/dev/null 2>&1 || exit 0

HERMES_HOME="$FOLLOWUP_ROOT/home" HERMES_TURNEND_GUARD_ACTIVE=1 \
  hermes --yolo --accept-hooks \
    -z "TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.

$REASON" >/dev/null 2>&1 || true
exit 0
