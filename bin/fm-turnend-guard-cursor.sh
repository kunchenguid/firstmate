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
#   2. pins `stop_hook_active: false` for the shared guard so the predicate is
#      evaluated on EVERY stop, including a forced follow-up turn: the arm is
#      stop-hook-owned, so a continuation whose own supervision need is real
#      must re-arm rather than end blind (the Claude --claude-mode lesson,
#      bin/fm-turnend-guard.sh:41-46). The shim owns the bound instead:
#      `loop_count` only caps how many consecutive loud failure follow-ups a
#      single continuation chain may emit (FM_CURSOR_TURNEND_BLOCK_BUDGET);
#   3. runs bin/fm-turnend-guard.sh with the normalized payload;
#   4. on exit 2 (a blind turn), foregrounds bin/fm-watch-arm.sh inside the
#      hook-owned process tree - parked while the watcher arms, never shell
#      & - then re-runs bin/fm-turnend-guard.sh against the post-arm state;
#   5. emits a normal wake followup when the arm reports a typed actionable
#      reason but the re-run still needs the model; a failed or untyped arm
#      keeps the loud guard banner, and any other exit emits {}.
#
# The translation layer is the grok-shim pattern (bin/fm-turnend-guard-grok.sh):
# a thin layer, zero changes to the shared predicate. The arm/park follows the
# claude auto-arm model (bin/fm-claude-stop-autoarm.sh): the hook-owned
# foreground tree is the arm lifecycle, and the watcher parks until an
# actionable wake closes the cycle or the hook timeout tears the tree down.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# loop_count > 0 means a previous stop-hook follow-up started this turn: the
# cursor spelling of a continuation. It bounds the loud failure follow-up only;
# the shared guard always sees stop_hook_active false so a continuation with a
# real supervision need still re-arms. A malformed payload passes through
# unchanged so the guard's own validation decides.
LOOP_COUNT=$(printf '%s' "$PAYLOAD" | jq -r '
  if type == "object" and (.loop_count | type) == "number" and .loop_count > 0
  then (.loop_count | floor) else 0 end
' 2>/dev/null) || LOOP_COUNT=0
case "$LOOP_COUNT" in ''|*[!0-9]*) LOOP_COUNT=0 ;; esac

BLOCK_BUDGET=${FM_CURSOR_TURNEND_BLOCK_BUDGET:-3}
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

NORMALIZED=$(printf '%s' "$PAYLOAD" | jq -c '
  if type != "object" then . else . + {stop_hook_active: false} end
' 2>/dev/null) || NORMALIZED=$PAYLOAD

ROOT=${CURSOR_WORKSPACE_ROOT:-${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor.XXXXXX") || exit 0
ARM_OUT=
ARM_ACTIONABLE=0
ARM_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor-arm.XXXXXX") || ARM_OUT=
trap 'rm -f "$ERR" "$ARM_OUT"' EXIT

printf '%s' "$NORMALIZED" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || { printf '{}\n'; exit 0; }

# Blind turn: park in the hook-owned foreground tree while the watcher arms.
# Never shell &: the harness owns this process group, so the hook timeout and
# turn end tear arm and watcher down together; a backgrounded child would be
# reaped at hook exit, leaving no watcher and a false "already running".
# shellcheck source=/dev/null
[ -f "$ROOT/config/x-mode.env" ] && . "$ROOT/config/x-mode.env"
if [ -n "$ARM_OUT" ]; then
  "$ROOT/bin/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 || true
  cat "$ARM_OUT" >&2
  if grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$ARM_OUT" 2>/dev/null; then
    ARM_ACTIONABLE=1
  fi
else
  "$ROOT/bin/fm-watch-arm.sh" >&2 || true
fi

# Re-run the guard against the post-arm state: a healthy watcher or vanished
# need allows the turn; an actionable arm close needs a wake even though no
# watcher remains; only an arm failure or untyped close keeps the blind banner.
printf '%s' "$NORMALIZED" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || { printf '{}\n'; exit 0; }

if [ "$ARM_ACTIONABLE" -eq 0 ] && [ "$LOOP_COUNT" -ge "$BLOCK_BUDGET" ]; then
  printf '{}\n'
  exit 0
fi

if [ "$ARM_ACTIONABLE" -eq 1 ]; then
  REASON='firstmate watcher wake - one supervision event needs a handling turn now. Run bin/fm-wake-drain.sh first and handle the wake. Stop-hook-owned continuity re-arms the next needed cycle automatically; do not manually arm the watcher.'
else
  REASON=$(cat "$ERR" 2>/dev/null || true)
  [ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
fi
# Render the reason as one JSON string: cursor shows the followup_message
# verbatim in the pane.
REASON=${REASON//\\/\\\\}
REASON=${REASON//\"/\\\"}
REASON=$(printf '%s' "$REASON" | tr '\n' ' ')
printf '{"followup_message":"%s"}\n' "$REASON"
exit 0
