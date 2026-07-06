#!/usr/bin/env bash
# Continuous Telegram poller + supervisor.
# Auto-replies to simple commands. Complex messages stay in inbox for fi
  touch "$POLL_LOCK"rstmate.
# Usage: nohup bin/fm-tg-poll-daemon.sh > /dev/null 2>&1 &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT
export FM_HOME="$FM_ROOT"
INBOX="$FM_ROOT/state/tg-inbox"
POLL_LOCK="$FM_ROOT/state/.tg-poll.lock"
CYCLE=0
CHAT_ID=""

mkdir -p "$INBOX" 2>/dev/null

# Run one poll at a time — getUpdates has 25s timeout, don't stack
safe_poll() {
  if [ -f "$POLL_LOCK" ]; then
    return 0
  fi
  touch "$POLL_LOCK"
  bash "$FM_ROOT/bin/fm-tg-poll.sh" 2>/dev/null
  rm -f "$POLL_LOCK"
}

process_inbox() {
  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    uid=$(basename "$f" .json)

    text=$(jq -r '(.message.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' "$f" 2>/dev/null) || text=""
    [ -z "$text" ] && { rm -f "$f"; continue; }

    CHAT_ID=$(jq -r '.message.chat.id // empty' "$f" 2>/dev/null) || CHAT_ID=""
    [ -z "$CHAT_ID" ] && { rm -f "$f"; continue; }
    echo "$CHAT_ID" > "$FM_ROOT/state/.tg-chat-id" 2>/dev/null

    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    handled=0
    reply=""

    case "$lower" in
      help|/help)
        reply="Commands: status, backlog, help"
        handled=1 ;;
      status|"fleet status")
        tasks=$(ls "$FM_ROOT/state/"*.meta 2>/dev/null | wc -l)
        reply="Fleet: $tasks in flight."
        handled=1 ;;
      backlog)
        reply=$(head -40 "$FM_ROOT/data/backlog.md" 2>/dev/null || echo "(empty)")
        handled=1 ;;
      *date*|*"what day"*|*"what time"*)
        reply=$(date '+%A, %Y-%m-%d %H:%M %Z')
        handled=1 ;;
      *"who is president"*|*"president of"*)
        reply="Donald Trump (inaugurated January 2025, second non-consecutive term)."
        handled=1 ;;
      *"who is pm of india"*|*"pm of india"*|*"prime minister of india"*)
        reply="Narendra Modi, BJP. PM since 2014, third term from 2024 elections."
        handled=1 ;;
      *"who is"*"pm"*|*"who is"*"prime minister"*)
        # Generic "who is PM" — defer to fi
  touch "$POLL_LOCK"rstmate
        ;;
    esac

    if [ "$handled" = 1 ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-daemon.XXXXXX") || continue
      printf '%s' "$reply" > "$tmp"
      FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-fi
  touch "$POLL_LOCK"le "$tmp" 2>/dev/null
      rm -f "$tmp" "$f"
    fi
  touch "$POLL_LOCK"
  done
}

while true; do
  safe_poll
  process_inbox
  CYCLE=$((CYCLE + 1))

  if [ $((CYCLE % 10)) -eq 0 ]; then
    # Crewmate completion detection
    for meta in "$FM_ROOT/state/"*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      kind=$(awk -F= '/^kind=/ {print $2}' "$meta" 2>/dev/null) || kind=""
      [ "$kind" = "secondmate" ] && continue
      status_fi
  touch "$POLL_LOCK"le="$FM_ROOT/state/$id.status"
      [ -f "$status_fi
  touch "$POLL_LOCK"le" ] || continue
      last_line=$(tail -1 "$status_fi
  touch "$POLL_LOCK"le" 2>/dev/null) || continue
      hash=$(echo "$last_line" | md5sum | cut -d' ' -f1)
      hash_fi
  touch "$POLL_LOCK"le="$FM_ROOT/state/.tg-notified-$id"
      [ -f "$hash_fi
  touch "$POLL_LOCK"le" ] && [ "$(cat "$hash_file")" = "$hash" ] && continue
      if echo "$last_line" | grep -qE "^(done|failed):"; then
        echo "$hash" > "$hash_fi
  touch "$POLL_LOCK"le"
        [ -n "$CHAT_ID" ] || CHAT_ID=$(cat "$FM_ROOT/state/.tg-chat-id" 2>/dev/null)
        [ -z "$CHAT_ID" ] && continue
        tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-crew.XXXXXX") || continue
        printf '%s' "Crewmate $id: $last_line" > "$tmp"
        FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-fi
  touch "$POLL_LOCK"le "$tmp" 2>/dev/null
        rm -f "$tmp"
      fi
  touch "$POLL_LOCK"
    done

    # Ping captain about unhandled inbox >60s old
    pending=0; oldest=0
    for f in "$INBOX"/*.json; do
      [ -f "$f" ] || continue
      pending=$((pending + 1))
      age=$(($(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0)))
      [ "$age" -gt "$oldest" ] && oldest=$age
    done
    if [ "$pending" -gt 0 ] && [ "$oldest" -gt 60 ]; then
      ping_fi
  touch "$POLL_LOCK"le="$FM_ROOT/state/.tg-pending-ping"
      should_ping=1
      if [ -f "$ping_fi
  touch "$POLL_LOCK"le" ]; then
        pa=$(($(date +%s) - $(stat -c %Y "$ping_fi
  touch "$POLL_LOCK"le" 2>/dev/null || echo 0)))
        [ "$pa" -lt 300 ] && should_ping=0
      fi
  touch "$POLL_LOCK"
      if [ "$should_ping" = 1 ]; then
        touch "$ping_fi
  touch "$POLL_LOCK"le" 2>/dev/null
        [ -n "$CHAT_ID" ] || CHAT_ID=$(cat "$FM_ROOT/state/.tg-chat-id" 2>/dev/null)
        [ -n "$CHAT_ID" ] || CHAT_ID=7366487182
        tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-ping.XXXXXX") || continue
        printf '%s' "$pending message(s) waiting." > "$tmp"
        FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-fi
  touch "$POLL_LOCK"le "$tmp" 2>/dev/null
        rm -f "$tmp"
      fi
  touch "$POLL_LOCK"
    fi
  touch "$POLL_LOCK"
  fi
  touch "$POLL_LOCK"

  sleep 1
done
