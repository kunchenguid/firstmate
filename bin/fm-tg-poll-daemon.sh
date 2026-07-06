#!/usr/bin/env bash
# Continuous Telegram poller + supervisor.
# Auto-replies to simple commands. Complex messages stay in inbox for firstmate.
# Usage: nohup bin/fm-tg-poll-daemon.sh > /dev/null 2>&1 &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT
export FM_HOME="$FM_ROOT"
INBOX="$FM_ROOT/state/tg-inbox"
CYCLE=0
CHAT_ID=""

mkdir -p "$INBOX" 2>/dev/null

while true; do
  bash "$FM_ROOT/bin/fm-tg-poll.sh" 2>/dev/null

  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    uid=$(basename "$f" .json)

    text=$(jq -r '(.message.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' "$f" 2>/dev/null) || text=""
    [ -z "$text" ] && { rm -f "$f"; continue; }

    CHAT_ID=$(jq -r '.message.chat.id // empty' "$f" 2>/dev/null) || CHAT_ID=""
    [ -z "$CHAT_ID" ] && { rm -f "$f"; continue; }

    # Persist chat_id for crewmate notifications
    echo "$CHAT_ID" > "$FM_ROOT/state/.tg-chat-id" 2>/dev/null

    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    handled=0
    reply=""

    case "$lower" in
      help|/help)
        reply="Commands:

status — fleet state
backlog — current backlog
help — this list"
        handled=1
        ;;
      status|"fleet status")
        tasks=$(ls "$FM_ROOT/state/"*.meta 2>/dev/null | wc -l)
        reply="Fleet — $tasks in flight."
        handled=1
        ;;
      backlog)
        reply=$(head -40 "$FM_ROOT/data/backlog.md" 2>/dev/null || echo "(empty)")
        handled=1
        ;;
      *date*|*"what day"*|*"what time"*)
        reply=$(date '+%A, %Y-%m-%d %H:%M %Z')
        handled=1
        ;;
    esac

    if [ "$handled" = 1 ]; then
      # Auto-replied: send answer, remove from inbox
      tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-daemon.XXXXXX") || continue
      printf '%s' "$reply" > "$tmp"
      FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-file "$tmp" 2>/dev/null
      rm -f "$tmp"
      rm -f "$f"
    fi
    # Complex messages: LEAVE in inbox for firstmate to handle.
    # Do NOT remove, do NOT send placeholder.
  done

  # Every 10 cycles (~10s), check crewmates + notify about pending inbox
  CYCLE=$((CYCLE + 1))
  if [ $((CYCLE % 10)) -eq 0 ]; then
    # Check for new crewmate completions
    for meta in "$FM_ROOT/state/"*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      kind=$(awk -F= '/^kind=/ {print $2}' "$meta" 2>/dev/null) || kind=""
      [ "$kind" = "secondmate" ] && continue

      status_file="$FM_ROOT/state/$id.status"
      [ -f "$status_file" ] || continue
      last_line=$(tail -1 "$status_file" 2>/dev/null) || continue

      hash=$(echo "$last_line" | md5sum | cut -d' ' -f1)
      hash_file="$FM_ROOT/state/.tg-notified-$id"
      [ -f "$hash_file" ] && [ "$(cat "$hash_file")" = "$hash" ] && continue

      if echo "$last_line" | grep -qE "^(done|failed):"; then
        echo "$hash" > "$hash_file"
        [ -n "$CHAT_ID" ] || CHAT_ID=$(cat "$FM_ROOT/state/.tg-chat-id" 2>/dev/null)
        [ -z "$CHAT_ID" ] && continue
        tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-crew.XXXXXX") || continue
        printf '%s' "Crewmate $id: $last_line" > "$tmp"
        FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-file "$tmp" 2>/dev/null
        rm -f "$tmp"
      fi
    done

    # If there are unhandled inbox messages older than 60s, ping captain
    pending=0
    oldest=0
    for f in "$INBOX"/*.json; do
      [ -f "$f" ] || continue
      pending=$((pending + 1))
      age=$(($(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0)))
      [ "$age" -gt "$oldest" ] && oldest=$age
    done
    if [ "$pending" -gt 0 ] && [ "$oldest" -gt 60 ]; then
      ping_file="$FM_ROOT/state/.tg-pending-ping"
      ping_age=0
      [ -f "$ping_file" ] && ping_age=$(($(date +%s) - $(stat -c %Y "$ping_file" 2>/dev/null || echo 0)))
      # Only ping at most every 5 minutes to avoid spam
      if [ "$ping_age" -gt 300 ] || [ ! -f "$ping_file" ]; then
        touch "$ping_file" 2>/dev/null
        [ -n "$CHAT_ID" ] || CHAT_ID=$(cat "$FM_ROOT/state/.tg-chat-id" 2>/dev/null)
        if [ -n "$CHAT_ID" ]; then
          tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-ping.XXXXXX") || continue
          printf '%s' "$pending message(s) waiting in inbox. Wake firstmate to handle." > "$tmp"
          FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-file "$tmp" 2>/dev/null
          rm -f "$tmp"
        fi
      fi
    fi
  fi

  sleep 1
done
