#!/usr/bin/env bash
# Continuous Telegram poller — polls every 1s, auto-replies with persistent typing indicator.
# Usage: nohup bin/fm-tg-poll-daemon.sh > /dev/null 2>&1 &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT
INBOX="$FM_ROOT/state/tg-inbox"
PROCESSED="$FM_ROOT/state/tg-processed"

mkdir -p "$INBOX" "$PROCESSED" 2>/dev/null

while true; do
  bash "$FM_ROOT/bin/fm-tg-poll.sh" 2>/dev/null

  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    uid=$(basename "$f" .json)
    [ -f "$PROCESSED/$uid" ] && continue

    text=$(jq -r '(.message.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' "$f" 2>/dev/null) || text=""
    [ -z "$text" ] && { touch "$PROCESSED/$uid" 2>/dev/null; continue; }

    chat_id=$(jq -r '.message.chat.id // empty' "$f" 2>/dev/null) || chat_id=
    [ -z "$chat_id" ] && { touch "$PROCESSED/$uid" 2>/dev/null; continue; }

    # Start typing indicator in background — keep refreshing every 4s
    TYPING_PID=""
    (
      while kill -0 $$ 2>/dev/null; do
        FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$chat_id" --text-file /dev/null --typing-only 2>/dev/null
        sleep 4
      done
    ) &
    TYPING_PID=$!

    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      help|/help)
        reply="Commands:

status — show fleet state
backlog — show current backlog
help — this list"
        ;;
      status|"fleet status")
        tasks_in_flight=$(ls "$FM_ROOT/state/"*.meta 2>/dev/null | wc -l)
        reply="Fleet state — $tasks_in_flight in flight."
        ;;
      backlog)
        reply=$(head -40 "$FM_ROOT/data/backlog.md" 2>/dev/null || echo "(no backlog)")
        ;;
      *)
        reply="Aye captain, processing: $text

(Forwarded to firstmate for full handling.)"
        ;;
    esac

    # Kill typing indicator
    [ -n "$TYPING_PID" ] && kill $TYPING_PID 2>/dev/null

    tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-daemon.XXXXXX") || continue
    printf '%s' "$reply" > "$tmp"
    FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$chat_id" --text-file "$tmp" 2>/dev/null
    rm -f "$tmp"
    touch "$PROCESSED/$uid" 2>/dev/null
  done

  sleep 1
done
