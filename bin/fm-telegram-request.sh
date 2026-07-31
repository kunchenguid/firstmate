#!/usr/bin/env bash
# Read or retire one accepted Telegram request by exact correlation ID.
#
# Usage:
#   fm-telegram-request.sh show <request_id>
#   fm-telegram-request.sh complete <request_id> <outbound_receipt_id>
#
# `show` prints only the minimal request object retained for Firstmate.
# `complete` removes the message body only after a matching sent outbound receipt
# proves that the request received its answer.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-telegram-request.sh show <request_id> | complete <request_id> <outbound_receipt_id>" >&2
}

command=${1:-}
request_id=${2:-}
fmtg_safe_slug "$request_id" 96 || { usage; exit 2; }
request_file="$FMTG_STATE/inbox/$request_id.json"

case "$command" in
  show)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    fmtg_retirement_matches "$request_id"
    retirement_status=$?
    case "$retirement_status" in
      0) echo "telegram request: request is already retired" >&2; exit 1 ;;
      1) ;;
      *) echo "telegram request: unsafe request retirement record" >&2; exit 1 ;;
    esac
    raw=$(fm_private_read_file "$request_file" 600) \
      || { echo "telegram request: unavailable or unsafe request record" >&2; exit 1; }
    view=$(printf '%s' "$raw" | jq -e '
      select(
        .schema == "firstmate.telegram-request.v1"
        and (.request_id | type == "string")
        and (.text | type == "string")
      )
      | {request_id,text,approval_intent,approval_id,approval_decision,telegram_message_id,reply_to_message_id,received_at}
    ') || { echo "telegram request: malformed request record" >&2; exit 1; }
    printf '%s\n' "$view" || exit 1
    fmtg_ack_request "$request_id" \
      || { echo "telegram request: could not acknowledge request offer" >&2; exit 1; }
    ;;
  complete)
    receipt_id=${3:-}
    if [ "$#" -ne 3 ] || ! fmtg_safe_slug "$receipt_id" 128; then
      usage
      exit 2
    fi
    receipt=$(fm_private_read_file "$FMTG_STATE/outbound/$receipt_id.json" 600) \
      || { echo "telegram request: matching sent receipt is required" >&2; exit 1; }
    if ! printf '%s' "$receipt" | jq -e --arg request_id "$request_id" '
      .schema == "firstmate.telegram-outbound.v1"
      and .state == "sent"
      and .request_id == $request_id
    ' >/dev/null 2>&1; then
      echo "telegram request: matching sent receipt is required" >&2
      exit 1
    fi
    fmtg_retire_request "$request_id" "$receipt_id" \
      || { echo "telegram request: could not retire request body" >&2; exit 1; }
    ;;
  *) usage; exit 2 ;;
esac
