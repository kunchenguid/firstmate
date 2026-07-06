#!/usr/bin/env bash
# Send a reply message to the captain via the Telegram Bot API.
#
# Usage: fm-tg-reply.sh <chat_id> --text-file <path>
#        fm-tg-reply.sh <chat_id> -
#
# The --text-file / stdin forms exist so a caller never has to inline reply
# text (which may be influenced by an incoming message) into a shell command.
#
# Sends via sendMessage to the given chat_id. On success it echoes the
# message_id from the Telegram response; on failure exits non-zero.
#
# Config (home .env or env): FMTG_BOT_TOKEN (required).
#
# Preview / dry-run: with FMTG_DRY_RUN set (truthy), the reply is NOT sent.
# Instead the would-be payload is recorded to state/tg-outbox/<chat_id>-<ts>.json
# and a "DRY RUN" summary is printed to stderr; stdout echoes a fake message_id
# and exit is 0. Dry-run needs neither a token nor the network.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

usage() {
  echo "usage: fm-tg-reply.sh <chat_id> --text-file <path> | fm-tg-reply.sh <chat_id> -" >&2
}

help() {
  cat <<'EOF'
usage: fm-tg-reply.sh <chat_id> --text-file <path>
       fm-tg-reply.sh <chat_id> -

Send a reply message to the captain via the Telegram Bot API.

Options:
  --text-file <path>  Read reply text from a file.
  -                   Read reply text from stdin.
  --help              Show this help.
EOF
}

case "${1:-}" in
  --help|-h) help; exit 0 ;;
esac

CHAT_ID=${1:-}
if [ -z "$CHAT_ID" ]; then
  usage
  exit 2
fi
shift

# Parse text source.
case "${1:-}" in
  --text-file)
    if [ "$#" -lt 2 ]; then
      echo "fm-tg-reply: missing --text-file path" >&2
      usage
      exit 2
    fi
    TEXT=$(cat -- "$2") || { echo "fm-tg-reply: cannot read text file: $2" >&2; exit 1; }
    ;;
  -)
    TEXT=$(cat)
    ;;
  *)
    usage
    exit 2
    ;;
esac
if [ -z "$TEXT" ]; then
  echo "fm-tg-reply: empty reply text" >&2
  exit 2
fi

# Validate chat_id is numeric.
case "$CHAT_ID" in
  ''|*[!0-9]*) echo "fm-tg-reply: invalid chat_id: $CHAT_ID" >&2; exit 2 ;;
esac

fmtg_load_config

command -v jq >/dev/null 2>&1 || { echo "fm-tg-reply: jq not found" >&2; exit 1; }

# Dry-run: record the payload and stop.
if [ -n "$FMTG_DRY" ]; then
  outbox_dir="$STATE/tg-outbox"
  outbox_file="$outbox_dir/$(date +%s)-${CHAT_ID}.json"
  mkdir -p "$outbox_dir" 2>/dev/null || {
    echo "fm-tg-reply: cannot create dry-run outbox: $outbox_dir" >&2
    exit 1
  }
  jq -cn --arg chat_id "$CHAT_ID" --arg text "$TEXT" \
    '{chat_id:$chat_id,text:$text}' > "$outbox_file" 2>/dev/null || {
    echo "fm-tg-reply: cannot write dry-run outbox: $outbox_file" >&2
    exit 1
  }
  printf 'fm-tg-reply: DRY RUN - would send to chat %s (recorded: state/tg-outbox/%s): %s\n' \
    "$CHAT_ID" "$(basename "$outbox_file")" "$TEXT" >&2
  printf 'dry-run-%s\n' "$(date +%s)"
  exit 0
fi

if [ -z "$FMTG_TOKEN" ]; then
  echo "fm-tg-reply: Telegram mode not configured (no FMTG_BOT_TOKEN)" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "fm-tg-reply: curl not found" >&2; exit 1; }

# Write the text to a temp file for fmtg_send_message.
TEXT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-tg-reply-text.XXXXXX") || exit 1
printf '%s' "$TEXT" > "$TEXT_FILE" || { rm -f "$TEXT_FILE"; exit 1; }

if ! response=$(fmtg_send_message "$CHAT_ID" "$TEXT_FILE"); then
  rm -f "$TEXT_FILE"
  echo "fm-tg-reply: failed to send message" >&2
  exit 1
fi
rm -f "$TEXT_FILE"

msg_id=$(printf '%s' "$response" | jq -r '.result.message_id // empty' 2>/dev/null) || msg_id=
if [ -z "$msg_id" ]; then
  echo "fm-tg-reply: could not extract message_id from response" >&2
  exit 1
fi
printf '%s\n' "$msg_id"
