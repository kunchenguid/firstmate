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
#   x_platform=<platform>      target platform, when known
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
# Fresh-link context resolution fills platform and explicit budget independently
# through the durable per-request registry, inbox payload, then authoritative
# relay lookup by request_id. If either axis remains missing, the link is still
# recorded but a loud warning is printed and follow-ups fail closed.
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

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
fm_pr_task_id_valid "$ID" || { echo "fm-x-link: unsafe task id: $ID" >&2; exit 2; }
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
REQ_PLATFORM=
REQ_EXPLICIT_MAX=
REQ_REPLY_MAX=
if [ -n "$CARRY_PLATFORM" ]; then
  REQ_PLATFORM=$CARRY_PLATFORM
fi
if [ -n "$CARRY_MAX" ]; then
  REQ_REPLY_MAX=$CARRY_MAX
fi

if [ -z "$CARRY_TS" ]; then
  REPLY_CONTEXT=$(fmx_resolve_reply_context "$STATE" "$RID" 1) || {
    echo "fm-x-link: failed to resolve request reply context" >&2
    exit 1
  }
  REQ_PLATFORM=$(printf '%s' "$REPLY_CONTEXT" | jq -r '.platform // ""')
  REQ_EXPLICIT_MAX=$(printf '%s' "$REPLY_CONTEXT" | jq -r '.reply_max_chars // ""')
  REQ_REPLY_MAX=$REQ_EXPLICIT_MAX
fi

if [ -n "$CARRY_TS" ] && { [ -z "$REQ_PLATFORM" ] || [ -z "$REQ_REPLY_MAX" ]; }; then
  echo "fm-x-link: relink requires carried reply context; pass --carry-platform and --carry-max from the prior task" >&2
  exit 2
fi

if [ -z "$CARRY_TS" ] && { [ -z "$REQ_PLATFORM" ] || [ -z "$REQ_REPLY_MAX" ]; }; then
  echo "fm-x-link: WARNING: incomplete authoritative reply context for request $RID; every completion follow-up will be HELD until both platform and explicit budget can be resolved. Ensure the relay request-context lookup supplies both values." >&2
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
