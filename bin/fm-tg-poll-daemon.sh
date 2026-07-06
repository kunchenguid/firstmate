#!/usr/bin/env bash
# Continuous firstmate supervisor — Telegram poll + crewmate monitor + wake relay.
# Usage: nohup bin/fm-tg-poll-daemon.sh > /dev/null 2>&1 &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT
export FM_HOME="$FM_ROOT"
INBOX="$FM_ROOT/state/tg-inbox"
PROCESSED="$FM_ROOT/state/tg-processed"
WAKE_QUEUE="$FM_ROOT/state/.wake-queue"
CYCLE=0

mkdir -p "$INBOX" "$PROCESSED" 2>/dev/null

while true; do
  # Poll Telegram for new messages
  bash "$FM_ROOT/bin/fm-tg-poll.sh" 2>/dev/null

  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    uid=$(basename "$f" .json)
    [ -f "$PROCESSED/$uid" ] && continue

    text=$(jq -r '(.message.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' "$f" 2>/dev/null) || text=""
    [ -z "$text" ] && { touch "$PROCESSED/$uid" 2>/dev/null; continue; }

    chat_id=$(jq -r '.message.chat.id // empty' "$f" 2>/dev/null) || chat_id=
    [ -z "$chat_id" ] && { touch "$PROCESSED/$uid" 2>/dev/null; continue; }

    # Start typing indicator
    TYPING_PID=""
    (
      while kill -0 $$ 2>/dev/null; do
        FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$chat_id" --text-file /dev/null --typing-only 2>/dev/null
        sleep 4
      done
    ) &
    TYPING_PID=$!

    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    reply=""
    case "$lower" in
      help|/help)
        reply="Commands:

status — fleet state
backlog — current backlog
help — this list"
        ;;
      status|"fleet status")
        tasks_in_flight=$(ls "$FM_ROOT/state/"*.meta 2>/dev/null | wc -l)
        reply="Fleet — $tasks_in_flight in flight."
        ;;
      backlog)
        reply=$(head -40 "$FM_ROOT/data/backlog.md" 2>/dev/null || echo "(empty)")
        ;;
      *date*|*"what day"*|*"what time"*)
        reply=$(date '+%A, %Y-%m-%d %H:%M %Z')
        ;;
      *)
        # Complex command: write to wake queue for firstmate, answer directly.
        # NO placeholder — firstmate handles it directly.
        epoch=$(date +%s)
        wake_key="${epoch}-tg-${uid}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "0" "tg" "$wake_key" "$text" >> "$WAKE_QUEUE"
        ;;
    esac

    [ -n "$TYPING_PID" ] && kill $TYPING_PID 2>/dev/null
    if [ -n "$reply" ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-daemon.XXXXXX") || continue
      printf '%s' "$reply" > "$tmp"
      FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$chat_id" --text-file "$tmp" 2>/dev/null
      rm -f "$tmp"
    fi
    touch "$PROCESSED/$uid" 2>/dev/null
  done

  # Every 10 cycles (~10s), check for crewmate state changes
  CYCLE=$((CYCLE + 1))
  if [ $((CYCLE % 10)) -eq 0 ]; then
    for meta in "$FM_ROOT/state/"*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      # Skip non-task meta (kind=secondmate, etc.)
      kind=$(awk -F= '/^kind=/ {print $2}' "$meta" 2>/dev/null) || kind=""
      [ "$kind" = "secondmate" ] && continue

      status_file="$FM_ROOT/state/$id.status"
      [ -f "$status_file" ] || continue
      last_line=$(tail -1 "$status_file" 2>/dev/null) || continue

      # Check if this is a new "done:" we haven't notified about
      hash=$(echo "$last_line" | md5sum | cut -d' ' -f1)
      hash_file="$FM_ROOT/state/.tg-notified-$id"
      [ -f "$hash_file" ] && [ "$(cat "$hash_file")" = "$hash" ] && continue

      # Looks new — notify
      if echo "$last_line" | grep -q "^done:"; then
        echo "$hash" > "$hash_file"
        epoch=$(date +%s)
        wake_key="${epoch}-tg-crew-${id}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "0" "tg" "$wake_key" "Crewmate ${id} finished: ${last_line}" >> "$WAKE_QUEUE"
      fi
    done

    # Check for unhandled tg wake queue items older than 30s — notify captain
    if [ -f "$WAKE_QUEUE" ]; then
      now=$(date +%s)
      while IFS=$'\t' read -r epoch _ kind key payload; do
        [ -n "$epoch" ] || continue
        age=$((now - epoch))
        [ "$age" -gt 30 ] || continue
        [ "$kind" = "tg" ] || continue
        # Avoid re-notification
        notified_file="$FM_ROOT/state/.tg-wake-$key"
        [ -f "$notified_file" ] && continue
        touch "$notified_file" 2>/dev/null
        # Short ping to captain
        tmp_wake=$(mktemp "${TMPDIR:-/tmp}/fmtg-wake.XXXXXX") || continue
        printf '%s\n' "Wake: $payload" > "$tmp_wake"
        FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" 7366487182 --text-file "$tmp_wake" 2>/dev/null
        rm -f "$tmp_wake"
      done < "$WAKE_QUEUE"
    fi
  fi

  sleep 1
done
