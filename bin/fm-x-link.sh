#!/usr/bin/env bash
# Link a spawned task to the X-mode mention that triggered it, so firstmate can
# post up to THREE completion follow-ups when the task lands (within a 7-day window).
#
# Usage: fm-x-link.sh <task-id> <request_id> [--carry-count <n> --carry-ts <epoch> [--carry-platform <x|discord>] [--carry-max <n>]]
#
# Records link lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   x_request=<request_id>     the relay-issued id the follow-up posts against
#   x_request_ts=<epoch>       link time, for the 7-day follow-up window
#   x_followups=<n>            follow-ups already posted against this binding
#   x_platform=<platform>      target platform, when known from inbox or carry flags
#   x_reply_max_chars=<n>      target split budget, when known
#
# A fresh link always starts x_followups at 0 and uses the current time for
# x_request_ts. --carry-count <n> and --carry-ts <epoch> are a required pair for
# re-linking the SAME request onto a successor task (e.g. a stuck-crewmate
# recovery that respawns under a new task id): the caller reads the prior task's
# x_followups and x_request_ts before its meta goes away and passes both here,
# so the new task does not get a fresh follow-up budget, a refreshed local
# window, or a dropped reply-platform context against a binding the relay
# already knows about. Pass --carry-platform and --carry-max from the prior
# task's x_platform and x_reply_max_chars when the original inbox file is gone.
#
# Platform resolution is ordering-proof. The fmx-respond ack path can drain the
# inbox file before the task is spawned and linked, which used to leave a fresh
# link with no platform and silently default longer Discord follow-ups to the X
# 280-char budget (mangling them into a numbered thread). So for a fresh link
# where neither the stashed inbox payload nor carry flags carry the platform,
# this asks the relay AUTHORITATIVELY by request_id (fmx_request_relay_context).
# If even the relay cannot resolve it, the link is still recorded but a loud
# WARNING is printed: platform context is never silently lost, and the follow-up
# budget never falls back to X without a visible reason.
#
# This is a separate step the fmx-respond skill runs AFTER fm-spawn.sh, so it
# never changes fm-spawn's interface. The follow-up itself - detection, the
# window/cap check, the post, and clearing the link - is owned by
# fm-x-followup.sh on the task's captain-relevant wakes. The meta read/write
# lives in fm-x-lib.sh.
#
# Both ids are relay/firstmate slugs that compose a filename, so they are guarded
# against path traversal even though they come from trusted callers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

usage() {
  echo "usage: fm-x-link.sh <task-id> <request_id> [--carry-count <n> --carry-ts <epoch> [--carry-platform <x|discord>] [--carry-max <n>]]" >&2
}

ID=${1:-}
RID=${2:-}
if [ -z "$ID" ] || [ -z "$RID" ]; then
  usage
  exit 2
fi
shift 2

CARRY_COUNT=
CARRY_TS=
CARRY_PLATFORM=
CARRY_MAX=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --carry-count)
      shift
      CARRY_COUNT=${1:-}
      case "$CARRY_COUNT" in
        ''|*[!0-9]*) echo "fm-x-link: --carry-count needs a non-negative integer" >&2; exit 2 ;;
      esac
      ;;
    --carry-ts)
      shift
      CARRY_TS=${1:-}
      case "$CARRY_TS" in
        ''|*[!0-9]*) echo "fm-x-link: --carry-ts needs a non-negative epoch integer" >&2; exit 2 ;;
      esac
      ;;
    --carry-platform)
      shift
      CARRY_PLATFORM=${1:-}
      case "$CARRY_PLATFORM" in
        discord|x) ;;
        twitter) CARRY_PLATFORM=x ;;
        *) echo "fm-x-link: --carry-platform needs x or discord" >&2; exit 2 ;;
      esac
      ;;
    --carry-max)
      shift
      CARRY_MAX=${1:-}
      case "$CARRY_MAX" in
        ''|*[!0-9]*) echo "fm-x-link: --carry-max needs an integer of at least 50" >&2; exit 2 ;;
        *) [ "$CARRY_MAX" -ge 50 ] 2>/dev/null || { echo "fm-x-link: --carry-max needs an integer of at least 50" >&2; exit 2; } ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [ -n "$CARRY_COUNT" ] && [ -z "$CARRY_TS" ]; then
  echo "fm-x-link: --carry-count requires --carry-ts to preserve the original follow-up window" >&2
  exit 2
fi
if [ -n "$CARRY_TS" ] && [ -z "$CARRY_COUNT" ]; then
  echo "fm-x-link: --carry-ts requires --carry-count to preserve the consumed follow-up count" >&2
  exit 2
fi
if { [ -n "$CARRY_PLATFORM" ] || [ -n "$CARRY_MAX" ]; } && { [ -z "$CARRY_COUNT" ] || [ -z "$CARRY_TS" ]; }; then
  echo "fm-x-link: --carry-platform and --carry-max require --carry-count and --carry-ts" >&2
  exit 2
fi

# task-id composes a path (state/<id>.meta); request_id composes a path elsewhere
# (the inbox/outbox record). Reject anything outside a safe slug for both.
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-link: unsafe task id: $ID" >&2; exit 2 ;;
esac
case "$RID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-link: unsafe request_id: $RID" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "fm-x-link: no such task: state/$ID.meta" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "fm-x-link: jq not found" >&2; exit 1; }
fmx_load_config
INBOX_CONTEXT=$(fmx_request_inbox_context "$STATE" "$RID") || {
  echo "fm-x-link: failed to inspect request platform context" >&2
  exit 1
}
REQ_PLATFORM=$(printf '%s' "$INBOX_CONTEXT" | jq -r '.platform // ""')
REQ_EXPLICIT_MAX=$(printf '%s' "$INBOX_CONTEXT" | jq -r '.reply_max_chars // ""')
case "$REQ_PLATFORM" in
  discord|x|'') ;;
  twitter) REQ_PLATFORM=x ;;
  *) REQ_PLATFORM= ;;
esac
REQ_REPLY_MAX=
if [ -n "$CARRY_PLATFORM" ]; then
  REQ_PLATFORM=$CARRY_PLATFORM
fi
if [ -n "$CARRY_MAX" ]; then
  REQ_REPLY_MAX=$CARRY_MAX
fi

# Authoritative fallback for a FRESH link (not a carry relink) whose inbox
# payload told us nothing: ask the relay by request_id. This is what makes the
# link-vs-inbox-cleanup ordering irrelevant - the request_id survives the inbox
# drain, so a Discord follow-up keeps its budget even when the link is recorded
# after the ack reply cleaned up the inbox file.
if [ -z "$CARRY_TS" ] && [ -z "$REQ_PLATFORM" ] && [ -z "$REQ_EXPLICIT_MAX" ]; then
  if RELAY_CONTEXT=$(fmx_request_relay_context "$RID"); then
    RELAY_PLATFORM=$(printf '%s' "$RELAY_CONTEXT" | jq -r '.platform // ""')
    RELAY_MAX=$(printf '%s' "$RELAY_CONTEXT" | jq -r '.reply_max_chars // ""')
    case "$RELAY_PLATFORM" in discord|x) REQ_PLATFORM=$RELAY_PLATFORM ;; esac
    case "$RELAY_MAX" in ''|*[!0-9]*) ;; *) REQ_EXPLICIT_MAX=$RELAY_MAX ;; esac
  fi
fi

if [ -z "$REQ_REPLY_MAX" ] && { [ -n "$REQ_PLATFORM" ] || [ -n "$REQ_EXPLICIT_MAX" ]; }; then
  REQ_REPLY_MAX=$(fmx_reply_limit_for_platform "$REQ_PLATFORM" "$REQ_EXPLICIT_MAX")
fi

if [ -n "$CARRY_TS" ] && [ -z "$REQ_PLATFORM" ] && [ -z "$REQ_REPLY_MAX" ]; then
  echo "fm-x-link: relink requires carried reply context; pass --carry-platform and --carry-max from the prior task" >&2
  exit 2
fi

# Loud, never-silent warning: a fresh link with no resolvable platform (inbox
# payload absent and the relay could not answer by request_id) means completion
# follow-ups will fall back to the X 280-char split budget, which wrongly threads
# a longer Discord reply. Record the link anyway, but make the loss visible.
if [ -z "$CARRY_TS" ] && [ -z "$REQ_PLATFORM" ] && [ -z "$REQ_REPLY_MAX" ]; then
  echo "fm-x-link: WARNING: no reply-platform context for request $RID (inbox payload absent and the relay did not resolve it by request_id); completion follow-ups will use the default X 280-char split budget and may wrongly split a longer Discord reply into a numbered thread. Link the task before the inbox file is drained, or ensure the relay request-context lookup is available." >&2
fi

FOLLOWUPS=0
if [ -n "$CARRY_TS" ]; then
  LINK_TS=$CARRY_TS
  FOLLOWUPS=$CARRY_COUNT
else
  # FMX_NOW_OVERRIDE keeps tests deterministic; production uses the wall clock.
  LINK_TS=${FMX_NOW_OVERRIDE:-$(date +%s)}
  case "$LINK_TS" in
    ''|*[!0-9]*) echo "fm-x-link: could not read the current time" >&2; exit 1 ;;
  esac
fi

if ! fmx_meta_link_set "$META" "$RID" "$LINK_TS" "$FOLLOWUPS" "$REQ_PLATFORM" "$REQ_REPLY_MAX"; then
  echo "fm-x-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to X request %s\n' "$ID" "$RID"
