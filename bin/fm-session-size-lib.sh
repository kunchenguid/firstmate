#!/usr/bin/env bash
# fm-session-size-lib.sh - how long a launched worker's conversation already is,
# read from its tool's own session file with no model call.
#
# Sourced, never executed. This file is the single owner of where each covered
# tool keeps a worker's session and how calls and context are counted there.
# bin/fm-send.sh uses it to advise a fresh worker instead of steering a very
# long one (docs/configuration.md "Context ceiling" owns the advice settings).
#
# fm_session_size <harness> <worktree> sets
#   FM_SESSION_CALLS    model calls the newest session in <worktree> has made
#   FM_SESSION_CONTEXT  context tokens its last call read
# and returns 0, or returns 1 with both empty when the tool is not covered or no
# readable session exists. Nothing is printed and nothing is written.
#
# Claude Code: the newest *.jsonl in <config>/projects/<slug>/, where <config> is
# CLAUDE_CONFIG_DIR or ~/.claude and <slug> is the worktree path with every
# character outside [A-Za-z0-9] replaced by `-`, tried as given and then with
# symlinks resolved. Calls are distinct assistant
# message ids (one response is split across several lines). Context is the last
# usage's input + cache_read + cache_creation, the sum warm-cache compaction
# reads (bin/fm-warm-compact-lib.sh).
#
# Codex: the newest rollout-*.jsonl under CODEX_HOME (or ~/.codex)/sessions,
# modified in the last FM_SESSION_SIZE_DAYS days (default 30), whose first
# session_meta line names <worktree>, as given or with symlinks resolved, as its
# cwd. Calls are its token_count
# events that carry usage; context is the last one's input_tokens.
#
# Every other tool is not covered.

FM_SESSION_CALLS=
FM_SESSION_CONTEXT=

fm_session_size_claude() {  # <worktree>
  local wt=$1 root dir='' path physical newest
  root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
  physical=$(cd "$wt" 2>/dev/null && pwd -P) || physical=$wt
  for path in "$wt" "$physical"; do
    dir="$root/$(printf '%s' "$path" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
    [ -d "$dir" ] && break
    dir=
  done
  [ -n "$dir" ] || return 1
  # shellcheck disable=SC2012 # names are Claude session uuids, never odd characters
  newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -n 1)
  [ -n "$newest" ] && [ -r "$newest" ] || return 1
  FM_SESSION_CALLS=$(grep -F '"type":"assistant"' "$newest" 2>/dev/null |
    grep -o '"id":"msg_[A-Za-z0-9_-]*"' | sort -u | wc -l | tr -d ' ')
  FM_SESSION_CONTEXT=$(tail -n 400 "$newest" 2>/dev/null | jq -R -r '
      fromjson? | select(.type == "assistant") | .message.usage // empty
      | select(type == "object")
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
    ' 2>/dev/null | tail -n 1)
}

fm_session_size_codex() {  # <worktree>
  local wt=$1 sessions days file newest='' newest_m=0 m physical
  sessions=${CODEX_HOME:-$HOME/.codex}/sessions
  physical=$(cd "$wt" 2>/dev/null && pwd -P) || physical=$wt
  [ -d "$sessions" ] || return 1
  days=${FM_SESSION_SIZE_DAYS:-30}
  case "$days" in '' | *[!0-9]*) days=30 ;; esac
  # One awk pass reads only each file's first line and prints the files whose
  # session_meta names the worktree; jq then confirms each candidate exactly.
  while IFS= read -r file; do
    head -n 1 "$file" 2>/dev/null | jq -e --arg wt "$wt" --arg pwt "$physical" 'select(.type == "session_meta") | (.payload.cwd == $wt or .payload.cwd == $pwt)' >/dev/null 2>&1 || continue
    m=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null) || continue
    if [ "$m" -gt "$newest_m" ]; then
      newest=$file
      newest_m=$m
    fi
  done < <(find "$sessions" -type f -name 'rollout-*.jsonl' -mtime "-$days" -exec awk -v a="\"cwd\":\"$wt\"" -v b="\"cwd\":\"$physical\"" \
    'FNR == 1 { if (index($0, a) || index($0, b)) print FILENAME; nextfile }' {} + 2>/dev/null)
  [ -n "$newest" ] || return 1
  FM_SESSION_CALLS=$(jq -r 'select(.type == "event_msg" and .payload.type == "token_count" and (.payload.info | type) == "object") | 1' "$newest" 2>/dev/null | wc -l | tr -d ' ')
  FM_SESSION_CONTEXT=$(jq -r 'select(.type == "event_msg" and .payload.type == "token_count" and (.payload.info | type) == "object") | .payload.info.last_token_usage.input_tokens // empty' "$newest" 2>/dev/null | tail -n 1)
}

fm_session_size() {  # <harness> <worktree>
  local harness=$1 wt=$2 rc=1
  FM_SESSION_CALLS=
  FM_SESSION_CONTEXT=
  [ -n "$wt" ] || return 1
  case "$harness" in
  claude) fm_session_size_claude "$wt" && rc=0 ;;
  codex) fm_session_size_codex "$wt" && rc=0 ;;
  esac
  case "$FM_SESSION_CALLS" in '' | *[!0-9]*) rc=1 ;; esac
  case "$FM_SESSION_CONTEXT" in *[!0-9]*) FM_SESSION_CONTEXT= ;; esac
  if [ "$rc" -ne 0 ]; then
    FM_SESSION_CALLS=
    FM_SESSION_CONTEXT=
  fi
  return "$rc"
}
