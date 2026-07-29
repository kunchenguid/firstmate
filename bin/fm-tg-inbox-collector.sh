#!/usr/bin/env bash
# Minimal Telegram collector — only polls for messages, never replies.
# Messages land in state/tg-inbox/. Firstmate answers them directly.
# Usage: nohup bin/fm-tg-inbox-collector.sh > /dev/null 2>&1 &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT FM_HOME="$FM_ROOT"
INBOX="$FM_ROOT/state/tg-inbox"
LOCK="$FM_ROOT/state/.tg-poll.lock"

mkdir -p "$INBOX" 2>/dev/null

while true; do
  [ -f "$LOCK" ] && { sleep 1; continue; }
  touch "$LOCK"
  bash "$FM_ROOT/bin/fm-tg-poll.sh" 2>/dev/null
  rm -f "$LOCK"
  sleep 1
done
