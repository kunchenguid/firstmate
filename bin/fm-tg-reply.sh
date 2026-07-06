#!/usr/bin/env bash
# Send a reply message to the captain via the Telegram Bot API.
#
# Usage: fm-tg-reply.sh <chat_id> --text-file <path> [--keyboard <json-file>]
#        fm-tg-reply.sh <chat_id> - [--keyboard <json-file>]
#
# The --text-file / stdin forms exist so a caller never has to inline reply
# text (which may be influenced by an incoming message) into a shell command.
#
# Sends via sendMessage to the given chat_id. With --keyboard, attaches an
# inline keyboard from the JSON file (containing an inline_keyboard array).
# On success it echoes the message_id from the Telegram response.
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
  echo "usage: fm-tg-reply.sh <chat_id> --text-file <path> [--keyboard <json-file>] | fm-tg-reply.sh <chat_id> - [--keyboard <json-file>]" >&2
}

help() {
  cat <<'EOF'
usage: fm-tg-reply.sh <chat_id> --text-file <path> [--keyboard <json-file>]
       fm-tg-reply.sh <chat_id> - [--keyboard <json-file>]

Send a reply message to the captain via the Telegram Bot API.

Options:
  --text-file <path>  Read reply text from a file.
  -                   Read reply text from stdin.
  --keyboard <file>   Attach an inline keyboard from a JSON file.
                      The file must contain a JSON array of button rows.
                      Example: [["Approve":"approve:id"],["Decline":"decline:id"]]
  --typing-only        Fire sendChatAction and exit (no message sent).
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

# Parse text source and optional keyboard.
KEYBOARD_FILE=""
TEXT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file)
      if [ "$#" -lt 2 ]; then
        echo "fm-tg-reply: missing --text-file path" >&2
        usage
        exit 2
      fi
      TEXT=$(cat -- "$2") || { echo "fm-tg-reply: cannot read text file: $2" >&2; exit 1; }
      shift 2
      ;;
    -)
      TEXT=$(cat)
      shift
      ;;
    --keyboard)
      if [ "$#" -lt 2 ]; then
        echo "fm-tg-reply: missing --keyboard file path" >&2
        usage
        exit 2
      fi
      KEYBOARD_FILE="$2"
      shift 2
      ;;
    --typing-only)
      TYPING_ONLY=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

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
  if [ -n "$KEYBOARD_FILE" ] && [ -f "$KEYBOARD_FILE" ]; then
    kb_json=$(jq -c '.' "$KEYBOARD_FILE" 2>/dev/null) || kb_json=
    if [ -n "$kb_json" ]; then
      jq -cn --arg chat_id "$CHAT_ID" --arg text "$TEXT" --argjson kb "$kb_json" \
        '{chat_id:$chat_id,text:$text,reply_markup:{inline_keyboard:$kb}}' > "$outbox_file" 2>/dev/null || {
        echo "fm-tg-reply: cannot write dry-run outbox: $outbox_file" >&2
        exit 1
      }
    else
      jq -cn --arg chat_id "$CHAT_ID" --arg text "$TEXT" \
        '{chat_id:$chat_id,text:$text}' > "$outbox_file" 2>/dev/null || {
        echo "fm-tg-reply: cannot write dry-run outbox: $outbox_file" >&2
        exit 1
      }
    fi
  else
    jq -cn --arg chat_id "$CHAT_ID" --arg text "$TEXT" \
      '{chat_id:$chat_id,text:$text}' > "$outbox_file" 2>/dev/null || {
      echo "fm-tg-reply: cannot write dry-run outbox: $outbox_file" >&2
      exit 1
    }
  fi
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

# Typing-only mode: fire sendChatAction and exit.
if [ "${TYPING_ONLY:-0}" = 1 ]; then
  fmtg_send_chat_action "$CHAT_ID" typing 2>/dev/null || true
  exit 0
fi

# Write the text to a temp file for the send functions.
TEXT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-tg-reply-text.XXXXXX") || exit 1
printf '%s' "$TEXT" > "$TEXT_FILE" || { rm -f "$TEXT_FILE"; exit 1; }

if [ -n "$KEYBOARD_FILE" ] && [ -f "$KEYBOARD_FILE" ]; then
  fmtg_send_chat_action "$CHAT_ID" typing || true
  if ! response=$(fmtg_send_message_with_keyboard "$CHAT_ID" "$TEXT_FILE" "$KEYBOARD_FILE"); then
    rm -f "$TEXT_FILE"
    echo "fm-tg-reply: failed to send message with keyboard" >&2
    exit 1
  fi
else
  fmtg_send_chat_action "$CHAT_ID" typing || true
  if ! response=$(fmtg_send_message "$CHAT_ID" "$TEXT_FILE"); then
    rm -f "$TEXT_FILE"
    echo "fm-tg-reply: failed to send message" >&2
    exit 1
  fi
fi
rm -f "$TEXT_FILE"

msg_id=$(printf '%s' "$response" | jq -r '.result.message_id // empty' 2>/dev/null) || msg_id=
if [ -z "$msg_id" ]; then
  echo "fm-tg-reply: could not extract message_id from response" >&2
  exit 1
fi
printf '%s\n' "$msg_id"
