#!/usr/bin/env bash
# DSH UserPromptSubmit adapter delivering the firstmate session-start digest
# before the first model request.
#
# DSH's SessionStart hook runs detached and its additionalContext lands AFTER
# the first request as a user-shaped message (verified 2026-09-16), which is the
# wrong tier for a session-start digest. UserPromptSubmit fires before the model
# call and its additionalContext is part of that request, so the digest rides
# that event instead.
#
# The digest IS bin/fm-session-start.sh's stdout. That script owns the
# read-only and STARTUP TRUNCATED banners, the read-once contract, fleet state
# and the single emitted operating block (its supervision-instructions stage).
# This adapter must therefore deliver that stdout WHOLE: rendering the
# operating block separately, or discarding the run's output, hands the agent
# operating instructions without the diagnosis that is supposed to govern them.
#
# UserPromptSubmit fires on every prompt, so delivery is gated once per session
# id. The gate is recorded only after a digest was actually produced, so a
# failed, refused or empty startup retries on the next prompt instead of being
# swallowed for the whole session.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

ROOT=${FM_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-session-start.sh" ] || exit 0

# state/ may not exist yet: a fresh checkout has none until
# fm-session-start.sh's lock creates it, so it is not a gate.
STATE=${FM_STATE_OVERRIDE:-$ROOT/state}
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
MARKER="$STATE/.dsh-sessionstart-delivered"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null || true)" = "$SESSION_ID" ]; then
  exit 0
fi

# DSH supplies no session-open source field, so the digest runs as a first
# startup. stderr stays out of the payload; the script's own banners ride
# stdout, which is what a hook transport carries.
DIGEST=$("$ROOT/bin/fm-session-start.sh" --source startup 2>/dev/null) || true

# An empty digest is not a delivery: leave the gate unset so the next prompt
# retries. fm-session-start.sh exits 0 on every path including a refused lock,
# so emptiness is the only signal that nothing was produced.
[ -n "$DIGEST" ] || exit 0

# A terminal alarm the guard raised in an earlier session is durable state. A
# session that died before the agent relayed it must still surface here, so the
# notice is prepended rather than lost. The guard's own healthy-reset owns
# clearing the latch; this read never removes it, or a genuine lapse would be
# reported once and then forgotten.
ALARM="$STATE/.dsh-turnend-fail-open"
if [ -e "$ALARM" ]; then
  DASHED=$(sed -n 's/^blocked //p' "$ALARM" 2>/dev/null || true)
  DIGEST=$(printf '%s\n\n%s' \
    "●  FIRSTMATE SUPERVISION ALARM: a previous turn-end spent this home's DSH Stop-hook block budget (raised ${DASHED:-unknown}), so that session ended unsupervised. Verify watcher supervision before relying on unattended operation." \
    "$DIGEST")
fi

# Durable record before delivery, the ordering firstmate uses everywhere else.
printf '%s\n' "$SESSION_ID" > "$MARKER" 2>/dev/null || true

jq -cn --arg c "$DIGEST" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
