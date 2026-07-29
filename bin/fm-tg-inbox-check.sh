#!/usr/bin/env bash
# Turn-start inbox drain — process all pending Telegram messages.
# Run at the start of every firstmate turn.

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
: "${FM_HOME:=$FM_ROOT}"
INBOX="$FM_ROOT/state/tg-inbox"
CHAT_ID_FILE="$FM_ROOT/state/.tg-chat-id"

[ -d "$INBOX" ] || exit 0

shopt -s nullglob
messages=( "$INBOX"/*.json )
[ ${#messages[@]} -gt 0 ] || exit 0

CHAT_ID=$(cat "$CHAT_ID_FILE" 2>/dev/null || echo "")
[ -z "$CHAT_ID" ] && CHAT_ID=7366487182

for f in "${messages[@]}"; do
  text=$(jq -r '(.message.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' "$f" 2>/dev/null) || text=""
  [ -z "$text" ] && { rm -f "$f"; continue; }

  echo "tg-inbox: $text"
  rm -f "$f"
done
