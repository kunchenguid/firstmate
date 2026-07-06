#!/usr/bin/env bash
# Continuous Telegram poller + supervisor.
# Auto-replies to simple commands. Complex messages stay in inbox for firstmate.
# Usage: nohup bin/fm-tg-poll-daemon.sh > /dev/null 2>&1 &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT
export FM_HOME="$FM_ROOT"
INBOX="$FM_ROOT/state/tg-inbox"
POLL_LOCK="$FM_ROOT/state/.tg-poll.lock"
CYCLE=0
CHAT_ID=""

mkdir -p "$INBOX" 2>/dev/null

safe_poll() {
  # PID-based lock with 60s stale timeout
  if [ -f "$POLL_LOCK" ]; then
    lock_pid=$(cat "$POLL_LOCK" 2>/dev/null) || lock_pid=""
    if [ -n "$lock_pid" ]; then
      lock_age=$(($(date +%s) - $(stat -c %Y "$POLL_LOCK" 2>/dev/null || echo 0)))
      if [ "$lock_age" -lt 60 ] && kill -0 "$lock_pid" 2>/dev/null; then
        return 0  # genuine active lock
      fi
    fi
    # Stale lock — remove it
    rm -f "$POLL_LOCK"
  fi
  echo $$ > "$POLL_LOCK"
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
      *"who is"*"president"*)
        reply="Donald Trump (inaugurated January 2025, second non-consecutive term)."
        handled=1 ;;
      *"who is"*"pm"*"india"*|*"prime minister"*"india"*)
        reply="Narendra Modi, BJP. PM since 2014, third term from 2024 elections."
        handled=1 ;;
    esac

    if [ "$handled" = 1 ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-daemon.XXXXXX") || continue
      printf '%s' "$reply" > "$tmp"
      FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-file "$tmp" 2>/dev/null
      rm -f "$tmp" "$f"
    fi
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
  fi

  sleep 1
done
