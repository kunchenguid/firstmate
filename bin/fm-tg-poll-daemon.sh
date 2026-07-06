#!/usr/bin/env bash
# Continuous Telegram poller + supervisor with DuckDuckGo knowledge fallback.
# Auto-replies to simple commands AND factual questions via DDG Instant Answer.
# Complex/unanswered questions stay in inbox for firstmate.
# Usage: nohup bin/fm-tg-poll-daemon.sh > /dev/null 2>&1 &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT
export FM_HOME="$FM_ROOT"
INBOX="$FM_ROOT/state/tg-inbox"
POLL_LOCK="$FM_ROOT/state/.tg-poll.lock"
CYCLE=0
CHAT_ID=""

mkdir -p "$INBOX" 2>/dev/null

# DuckDuckGo instant answer lookup
ddg_lookup() {
  local q="$1" encoded ans
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$q" 2>/dev/null) || return 1
  ans=$(curl -s --max-time 5 "https://api.duckduckgo.com/?q=${encoded}&format=json&no_html=1" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
a=d.get('Answer','') or d.get('AbstractText','')
print(a.strip()[:400] if a else '')
" 2>/dev/null) || return 1
  [ -n "$ans" ] && printf '%s' "$ans" && return 0
  return 1
}

safe_poll() {
  [ -f "$POLL_LOCK" ] && return 0
  touch "$POLL_LOCK" 2>/dev/null || return 0
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
        reply="Commands: status, backlog, help. Or ask me anything!"
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
      *project*|*"working on"*)
        reply=$(cat "$FM_ROOT/data/projects.md" 2>/dev/null || echo "(no projects)")
        handled=1 ;;
      *ticker*|*strategy*buy*|*spread*bet*)
        # Check latest signals and HALT state
        halt=$(cat /home/m_gogate/hermes/stock_data/HALT 2>/dev/null || echo "unknown")
        sigs_file=$(ls -t /home/m_gogate/hermes/strategies-to-test/results/ig_forward/signals/*.json 2>/dev/null | head -1)
        if [ -n "$sigs_file" ]; then
          tickers=$(python3 -c "
import json
with open('$sigs_file') as f: data = json.load(f)
r14 = [s['ticker'] for s in data.get('signals',[]) if 'legacy_any_rsi14gated' in s.get('strategies',[])]
print(', '.join(sorted(r14)) if r14 else 'none')
" 2>/dev/null) || tickers="error"
          reply="HALT: $halt. rsi14gated tickers: $tickers."
        else
          reply="HALT: $halt. No signal file found."
        fi
        handled=1 ;;
      *armed*|*halt*|*paper*trading*)
        halt=$(cat /home/m_gogate/hermes/stock_data/HALT 2>/dev/null || echo "not found")
        reply="Paper trading HALT file: $halt"
        handled=1 ;;
      *crew*|*flight*|*task*|*subagent*|*agent*active*)
        tasks=$(ls "$FM_ROOT/state/"*.meta 2>/dev/null | wc -l)
        if [ "$tasks" -gt 0 ]; then
          details=""
          for m in "$FM_ROOT/state/"*.meta; do
            [ -f "$m" ] || continue
            id=$(basename "$m" .meta)
            kind=$(awk -F= '/^kind=/ {print $2}' "$m" 2>/dev/null) || kind=""
            [ "$kind" = "secondmate" ] && continue
            last=$(tail -1 "$FM_ROOT/state/$id.status" 2>/dev/null || echo "running")
            details="$details\n  $id: $last"
          done
          reply="$tasks in flight:$details"
        else
          reply="No tasks in flight."
        fi
        handled=1 ;;
      *"who are you"*|*"what are you"*)
        reply="Firstmate — your AI pair programmer and fleet supervisor. I manage crewmates across your projects."
        handled=1 ;;
      *count*|*calculate*|*math*)
        reply="Yes, I can count. Try me."
        handled=1 ;;
    esac

    # If no pattern match, try DuckDuckGo
    if [ "$handled" = 0 ]; then
      ddg_ans=$(ddg_lookup "$text" 2>/dev/null) || ddg_ans=""
      if [ -n "$ddg_ans" ]; then
        reply="$ddg_ans"
        handled=1
      fi
    fi

    if [ "$handled" = 1 ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/fmtg-daemon.XXXXXX") || continue
      printf '%s' "$reply" > "$tmp"
      FM_HOME="$FM_ROOT" bash "$FM_ROOT/bin/fm-tg-reply.sh" "$CHAT_ID" --text-file "$tmp" 2>/dev/null
      rm -f "$tmp" "$f"
    fi
  done
}

while true; do
  process_inbox
  safe_poll
  CYCLE=$((CYCLE + 1))

  if [ $((CYCLE % 10)) -eq 0 ]; then
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
