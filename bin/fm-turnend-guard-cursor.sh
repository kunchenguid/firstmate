#!/usr/bin/env bash
# Cursor Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Cursor's `stop` hook differs from Claude's and Codex's in exactly one
# place: it does not honour exit code 2 as a forced continuation. A stop hook
# that exits 2 with a rendered stderr banner simply ends the turn, so the
# shared guard's blind-turn signal must be translated into the mechanism
# cursor does honour: a JSON body on stdout with a `followup_message`.
#
# This shim (verified against cursor-agent 2026.07.23-e383d2b, 2026-08-05):
#   1. reads the cursor stop payload from stdin;
#   2. maps `loop_count > 0` to `stop_hook_active: true` so the shared
#      guard's existing loop guard applies unchanged (a forced follow-up is
#      a continuation, exactly like Claude's stop_hook_active / Codex's
#      stop_hook_active, and must not re-block on every rewake);
#   3. runs bin/fm-turnend-guard.sh with the normalized payload;
#   4. on exit 2, emits {"followup_message": "<captured stderr>"} on stdout
#      and exits 0 (cursor auto-submits the message as a new turn); on any
#      other exit it emits {} and exits 0 so the turn ends normally.
#
# The shape is the grok-shim pattern (bin/fm-turnend-guard-grok.sh): a thin
# translation layer, zero changes to the shared predicate.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# Normalize the cursor payload for the shared guard: loop_count > 0 means a
# previous stop-hook follow-up started this turn, which is the cursor spelling
# of stop_hook_active. Loop_count 0 (or absent) is a first turn end and stays
# false. A malformed payload passes through unchanged so the guard's own
# validation decides.
NORMALIZED=$(printf '%s' "$PAYLOAD" | jq -c '
  if type != "object" then .
  else
    if ((.loop_count | type) == "number" and .loop_count > 0) then
      . + {stop_hook_active: true}
    else
      .
    end
  end
' 2>/dev/null) || NORMALIZED=$PAYLOAD

ROOT=${CURSOR_WORKSPACE_ROOT:-${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$NORMALIZED" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || { printf '{}\n'; exit 0; }

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
# Render the banner as one JSON string: cursor shows the followup_message
# verbatim in the pane, so the actionable repair line must survive intact.
REASON=${REASON//\\/\\\\}
REASON=${REASON//\"/\\\"}
REASON=$(printf '%s' "$REASON" | tr '\n' ' ')
printf '{"followup_message":"%s"}\n' "$REASON"
exit 0
