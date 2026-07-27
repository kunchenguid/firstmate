#!/usr/bin/env bash
# Best-effort bridge from Firstmate lifecycle transitions to brain-event.
#
# Usage:
#   fm-brain-event.sh <action> <type> <task-id> <identity> <text> [brain-event args...]
#
# The caller supplies a stable, non-secret identity for the transition. This
# helper hashes it into an idempotency key, so retries materialize once. Missing
# brain-event is a supported no-op; a configured command that fails is surfaced
# as a warning but never changes the Firstmate lifecycle outcome.
set -u

if [ "$#" -lt 5 ]; then
  echo "warning: fm-brain-event: invalid invocation" >&2
  exit 0
fi

ACTION=$1
TYPE=$2
TASK_ID=$3
IDENTITY=$4
TEXT=$5
shift 5

case "$ACTION" in
  *[!a-z0-9-]*|'')
    echo "warning: fm-brain-event: invalid action" >&2
    exit 0
    ;;
esac
case "$TYPE" in
  SESSION_START|SESSION_END|TASK_START|TASK_DONE|TASK_BLOCKED|DECISION|PLAN_CHANGE|DEPLOY|ERROR|INSIGHT|HANDOFF|NOTE) ;;
  *)
    echo "warning: fm-brain-event: invalid type" >&2
    exit 0
    ;;
esac
case "$TASK_ID" in
  *[!A-Za-z0-9._-]*|'')
    echo "warning: fm-brain-event: invalid task id" >&2
    exit 0
    ;;
esac
[ -n "$IDENTITY" ] || {
  echo "warning: fm-brain-event: empty transition identity" >&2
  exit 0
}

EVENT_COMMAND=${FM_BRAIN_EVENT_COMMAND:-}
if [ -z "$EVENT_COMMAND" ]; then
  if command -v brain-event >/dev/null 2>&1; then
    EVENT_COMMAND=$(command -v brain-event)
  elif [ -x "${HOME:-}/.local/bin/brain-event" ]; then
    EVENT_COMMAND="${HOME}/.local/bin/brain-event"
  else
    exit 0
  fi
fi
[ -x "$EVENT_COMMAND" ] || {
  echo "warning: fm-brain-event: configured command is not executable" >&2
  exit 0
}

if command -v shasum >/dev/null 2>&1; then
  DIGEST=$(printf '%s\0%s\0%s' "$ACTION" "$TASK_ID" "$IDENTITY" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  DIGEST=$(printf '%s\0%s\0%s' "$ACTION" "$TASK_ID" "$IDENTITY" | sha256sum | awk '{print $1}')
else
  echo "warning: fm-brain-event: no SHA-256 utility available" >&2
  exit 0
fi
EVENT_ID="firstmate:${ACTION}:${DIGEST%"${DIGEST#????????????????????????????????}"}"

if ! BRAIN_AGENT=firstmate "$EVENT_COMMAND" "$TYPE" "$TEXT" \
  --event-id "$EVENT_ID" \
  --source-kind firstmate \
  --task-id "$TASK_ID" \
  --project firstmate \
  --quiet \
  "$@"; then
  echo "warning: fm-brain-event: lifecycle event was not accepted (action=$ACTION task=$TASK_ID)" >&2
fi
exit 0
