#!/usr/bin/env bash
# Codex Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Codex currently persists a blocking Stop continuation as a synthetic
# <hook_prompt> item with a bare UUID, then rejects that id on a later Desktop
# follow-up because Responses API item ids must begin with msg_ (openai/codex#20783).
# Keep using the shared primary-scoped predicate, but fail open at the Codex hook
# boundary until upstream fixes the serialization bug. When the predicate says
# the primary would end blind, return a non-blocking systemMessage and enqueue the
# warning so the next supervision checkpoint or session start sees durable evidence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/fm-turnend-guard.sh"
[ -x "$GUARD" ] || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-codex.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$GUARD" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='TURN WOULD END BLIND - tasks are in flight without a live watcher.'

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_wake_append check codex-turnend-guard \
  'check: Codex turn-end guard allowed the stop to protect session history; resume the foreground supervision checkpoint.' \
  >/dev/null 2>&1 || true

WARNING=$(printf '%s\n\n%s' "$REASON" 'Codex workaround: stop allowed and warning queued durably because openai/codex#20783 makes blocking Stop continuations corrupt later Desktop follow-ups.')
jq -cn --arg warning "$WARNING" '{continue:true,systemMessage:$warning}' 2>/dev/null || true
exit 0
