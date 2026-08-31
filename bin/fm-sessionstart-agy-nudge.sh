#!/usr/bin/env bash
# AGY (Antigravity CLI) PreInvocation adapter for the session-start nudge tier.
#
# AGY has NO SessionStart hook; its PreInvocation event fires before every model
# call and can inject steps into the upcoming invocation. Registration lives in
# the tracked .agents/hooks.json. This adapter gates on the first invocation of a
# session (`invocationNum == 0`, verified from the AGY hooks contract) and turns
# bin/fm-sessionstart-nudge.sh's one-line marked instruction into an
# `injectSteps[].ephemeralMessage`, which the model sees in context - strictly
# better than Grok's pane-only nudge (docs/sessionstart-nudge.md owns the NUDGE
# tier contract; fm-sessionstart-nudge.sh owns the scope, lock, and gate-agent
# checks and prints nothing when the digest is not owed).
#
# Every silence and every non-first-invocation path prints `{}` and exits 0:
# AGY requires a JSON object on stdout and a malformed response must never block
# or corrupt a model call. The nudge payload itself always exits 0, so the only
# error surface left here is JSON construction, which falls back to `{}`.
#
# Usage:
#   <PreInvocation JSON on stdin> | bin/fm-sessionstart-agy-nudge.sh
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || { printf '{}\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '{}\n'; exit 0; }

# invocationNum is a number; a missing field is not the first invocation, and a
# malformed one stands the adapter down so a broken payload cannot nudge forever.
NUM=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("invocationNum") then
    if ((.invocationNum | type) == "number") then (.invocationNum | floor) else error("invocationNum") end
  else -1
  end
' 2>/dev/null) || { printf '{}\n'; exit 0; }
case "$NUM" in ''|*[!0-9-]*) printf '{}\n'; exit 0 ;; esac
[ "$NUM" -eq 0 ] || { printf '{}\n'; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUDGE=$( "$SCRIPT_DIR/fm-sessionstart-nudge.sh" 2>/dev/null || true )
[ -n "$NUDGE" ] || { printf '{}\n'; exit 0; }
jq -cn --arg m "$NUDGE" '{injectSteps:[{ephemeralMessage:$m}]}' 2>/dev/null \
  || printf '{}\n'
exit 0
