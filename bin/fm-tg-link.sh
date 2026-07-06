#!/usr/bin/env bash
# Link a spawned task to the Telegram message that triggered it, so firstmate
# can post up to THREE completion follow-ups when the task lands (within a
# 7-day window).
#
# Usage: fm-tg-link.sh <task-id> <chat_id> <message_id> [--carry-count <n> --carry-ts <epoch>]
#
# Records four lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   tg_chat=<chat_id>          the Telegram chat the message came from
#   tg_message=<message_id>    the Telegram message_id for threaded replies
#   tg_followups=<n>            follow-ups already posted against this binding
#   tg_link_ts=<epoch>         link time, for the 7-day follow-up window
#
# A fresh link always starts tg_followups at 0 and uses the current time for
# tg_link_ts. --carry-count <n> and --carry-ts <epoch> are a required pair for
# re-linking the SAME message onto a successor task (e.g. a stuck-crewmate
# recovery that respawns under a new task id).
#
# This is a separate step the fmtg-respond skill runs AFTER fm-spawn.sh, so it
# never changes fm-spawn's interface. The follow-up itself is owned by
# fm-tg-followup.sh on the task's captain-relevant wakes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

usage() {
  echo "usage: fm-tg-link.sh <task-id> <chat_id> <message_id> [--carry-count <n> --carry-ts <epoch>]" >&2
}

ID=${1:-}
CHAT_ID=${2:-}
MSG_ID=${3:-}
if [ -z "$ID" ] || [ -z "$CHAT_ID" ] || [ -z "$MSG_ID" ]; then
  usage
  exit 2
fi
shift 3

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

# Validate chat_id and message_id are numeric (Telegram API requirement).
case "$CHAT_ID" in
  ''|*[!0-9]*) echo "fm-tg-link: unsafe chat_id: $CHAT_ID" >&2; exit 2 ;;
esac
case "$MSG_ID" in
  ''|*[!0-9]*) echo "fm-tg-link: unsafe message_id: $MSG_ID" >&2; exit 2 ;;
esac

# task-id composes a path (state/<id>.meta). Reject anything outside a safe slug.
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-tg-link: unsafe task id: $ID" >&2; exit 2 ;;
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

if ! fmtg_meta_link_set "$META" "$CHAT_ID" "$MSG_ID" "$LINK_TS" "$FOLLOWUPS"; then
  echo "fm-tg-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to Telegram chat %s message %s\n' "$ID" "$CHAT_ID" "$MSG_ID"
