#!/usr/bin/env bash
# Link a spawned task to the X mention that triggered it, so firstmate can post
# up to THREE completion follow-ups when the task lands (within a 7-day window).
#
# Usage: fm-x-link.sh <task-id> <request_id> [--carry-count <n> --carry-ts <epoch>]
#
# Records three lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   x_request=<request_id>     the relay-issued id the follow-up posts against
#   x_request_ts=<epoch>       link time, for the 7-day follow-up window
#   x_followups=<n>            follow-ups already posted against this binding
#
# A fresh link always starts x_followups at 0 and uses the current time for
# x_request_ts. --carry-count <n> and --carry-ts <epoch> are a required pair for
# re-linking the SAME request onto a successor task (e.g. a stuck-crewmate
# recovery that respawns under a new task id): the caller reads the prior task's
# x_followups and x_request_ts before its meta goes away and passes both here,
# so the new task does not get a fresh follow-up budget or a refreshed local
# window against a binding the relay already knows about.
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
  echo "usage: fm-x-link.sh <task-id> <request_id> [--carry-count <n> --carry-ts <epoch>]" >&2
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

if ! fmx_meta_link_set "$META" "$RID" "$LINK_TS" "$FOLLOWUPS"; then
  echo "fm-x-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to X request %s\n' "$ID" "$RID"
