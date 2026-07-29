#!/usr/bin/env bash
# Link a spawned task to the Telegram note that triggered it, so firstmate can
# send completion follow-ups to the captain's phone when the task lands.
#
# Usage: fm-tg-link.sh <task-id> <note-id> [--carry-count <n> --carry-ts <epoch>]
#
# Records link lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   tg_note=<note-id>       the phone-inbox note id the work came from
#   tg_note_ts=<epoch>      link time, for the follow-up window
#   tg_followups=<n>        follow-ups already sent against this link
#
# A fresh link always starts tg_followups at 0 and uses the current time for
# tg_note_ts (FMTG_NOW_OVERRIDE keeps tests deterministic). --carry-count <n>
# and --carry-ts <epoch> are a required pair for re-linking the SAME note onto
# a successor task (e.g. a stuck-crewmate recovery that respawns under a new
# task id), so the successor keeps the consumed follow-up count and the
# original window instead of a fresh budget.
#
# This is a separate step the fmtg-respond skill runs AFTER fm-spawn.sh, so it
# never changes fm-spawn's interface. The follow-up itself - the window/cap
# check, the send, and clearing the link - is owned by fm-tg-followup.sh on the
# task's captain-relevant wakes. The meta read/write lives in fm-tg-lib.sh.
# Unlike fm-x-link.sh there is no platform or budget context to resolve:
# Telegram has one chat and the phone-inbox `tg` client owns message limits.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-tg-link.sh <task-id> <note-id> [--carry-count <n> --carry-ts <epoch>]" >&2
}

ID=${1:-}
NID=${2:-}
if [ -z "$ID" ] || [ -z "$NID" ]; then
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
        ''|*[!0-9]*) echo "fm-tg-link: --carry-count needs a non-negative integer" >&2; exit 2 ;;
      esac
      ;;
    --carry-ts)
      shift
      CARRY_TS=${1:-}
      case "$CARRY_TS" in
        ''|*[!0-9]*) echo "fm-tg-link: --carry-ts needs a non-negative epoch integer" >&2; exit 2 ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [ -n "$CARRY_COUNT" ] && [ -z "$CARRY_TS" ]; then
  echo "fm-tg-link: --carry-count requires --carry-ts to preserve the original follow-up window" >&2
  exit 2
fi
if [ -n "$CARRY_TS" ] && [ -z "$CARRY_COUNT" ]; then
  echo "fm-tg-link: --carry-ts requires --carry-count to preserve the consumed follow-up count" >&2
  exit 2
fi

# task-id composes a path (state/<id>.meta); the note id names an offered
# marker elsewhere. Reject anything outside the safe shapes for both.
fm_pr_task_id_valid "$ID" || { echo "fm-tg-link: unsafe task id: $ID" >&2; exit 2; }
case "$NID" in
  ''|*[!0-9]*) echo "fm-tg-link: unsafe note id: $NID" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "fm-tg-link: no such task: state/$ID.meta" >&2
  exit 1
fi

FOLLOWUPS=0
if [ -n "$CARRY_TS" ]; then
  LINK_TS=$CARRY_TS
  FOLLOWUPS=$CARRY_COUNT
else
  LINK_TS=${FMTG_NOW_OVERRIDE:-$(date +%s)}
  case "$LINK_TS" in
    ''|*[!0-9]*) echo "fm-tg-link: could not read the current time" >&2; exit 1 ;;
  esac
fi

if ! fmtg_meta_link_set "$META" "$NID" "$LINK_TS" "$FOLLOWUPS"; then
  echo "fm-tg-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to telegram note %s\n' "$ID" "$NID"
