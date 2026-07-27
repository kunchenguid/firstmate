#!/usr/bin/env bash
# Best-effort bridge from Firstmate lifecycle transitions to brain-event.
#
# Usage:
#   fm-brain-event.sh <action> <type> <task-id> <identity> <text> [brain-event args...]
#
# The caller supplies a stable, non-secret identity for the transition. This
# helper hashes it into an idempotency key, so retries materialize once. Missing
# brain-event is a supported no-op; a configured command that fails or stalls is
# surfaced as a warning but never changes the Firstmate lifecycle outcome. The
# call is bounded by FM_BRAIN_EVENT_TIMEOUT seconds (default 10) wherever a
# timeout utility exists.
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
EVENT_ID="firstmate:${ACTION}:${DIGEST:0:32}"

EVENT_TIMEOUT=${FM_BRAIN_EVENT_TIMEOUT:-10}
case "$EVENT_TIMEOUT" in
  ''|*[!0-9]*) EVENT_TIMEOUT=10 ;;
esac
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
bounded_event() {  # <command> [args...]
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$EVENT_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$EVENT_TIMEOUT" "$@" ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$EVENT_TIMEOUT" "$@" ;;
    *)        "$@" ;;
  esac
}

export BRAIN_AGENT=firstmate
if ! bounded_event "$EVENT_COMMAND" "$TYPE" "$TEXT" \
  --event-id "$EVENT_ID" \
  --source-kind firstmate \
  --task-id "$TASK_ID" \
  --project firstmate \
  --quiet \
  "$@"; then
  echo "warning: fm-brain-event: lifecycle event was not accepted (action=$ACTION task=$TASK_ID)" >&2
fi
exit 0
