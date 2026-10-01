#!/usr/bin/env bash
# fm-prior-sessions.sh - name this home's newest primary-session transcripts.
#
# A home can alternate primary harnesses (for example Pi one session and Kiro
# the next), and the captain's answer to a decision often lives only in the
# conversation where he gave it: a chat reply or an ask-tool pick that left no
# durable record. A new session that cannot see that conversation would then
# tell the captain a call he already made is still open. The session-start
# digest prints this script's output so the new session knows where the
# previous conversations are and checks them before re-asking.
#
# This script prints PATHS ONLY. It never reads, prints, or copies transcript
# content; the reader opens a named file itself when it needs to confirm an
# answer, and never copies that content into tracked material.
#
# Covered harnesses and where each persists a conversation for a working
# directory <dir> (the home path, logical and physical spellings both tried):
#   pi      ${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions/--<dir without its
#           leading slash, every / replaced by ->--/*.jsonl
#   kiro    $HOME/.kiro/sessions/<first 16 hex of sha256(<dir>)>/<session>/
#           messages.jsonl, kept only when that session's session.json lists
#           <dir> in workspacePaths
#   claude  $HOME/.claude/projects/<dir with every non-alphanumeric character
#           replaced by ->/*.jsonl
# Other harnesses (codex, opencode, cursor, grok, kimi, omp) keep conversations
# in date-sharded trees or databases that need a content scan to attribute to a
# directory, so they are not listed; a home on one of them prints nothing extra.
# Every lookup is one directory listing, never a walk of every session.
#
# Output: one line per transcript, newest first, at most --limit lines
# (default 3):
#   <harness>  <YYYY-MM-DDTHH:MMZ last write>  <absolute path>
# The newest line is usually the current session itself. No transcript found
# prints nothing. Always exits 0 on a lookup miss; exits 2 on a usage error.
#
# Usage: FM_HOME=<home> fm-prior-sessions.sh [--limit N]
set -u

usage() { sed -n '/^# Usage:/s/^# //p' "$0"; }

LIMIT=3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      LIMIT=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$LIMIT" in ''|*[!0-9]*|0) usage >&2; exit 2 ;; esac
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME must be set" >&2; exit 2; }

if [ "$(uname -s)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

utc_minute() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null
}

sha16() {  # <text>
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
  fi
}

DIRS=$FM_HOME
PHYS=$(cd -P -- "$FM_HOME" 2>/dev/null && pwd) || PHYS=
[ -z "$PHYS" ] || [ "$PHYS" = "$FM_HOME" ] || DIRS="$DIRS
$PHYS"

emit() {  # <harness> <path>
  local m
  m=$(file_mtime "$2") || return 0
  [ -n "$m" ] || return 0
  printf '%s\t%s\t%s\n' "$m" "$1" "$2"
}

collect() {
  local dir enc hash sess
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    enc=${dir#/}
    for f in "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions/--${enc//\//-}--"/*.jsonl; do
      [ -f "$f" ] && emit pi "$f"
    done
    hash=$(sha16 "$dir")
    if [ -n "$hash" ] && command -v jq >/dev/null 2>&1; then
      for sess in "$HOME/.kiro/sessions/$hash"/*/; do
        [ -f "${sess}messages.jsonl" ] || continue
        jq -e --arg d "$dir" '(.workspacePaths // []) | index($d) != null' \
          "${sess}session.json" >/dev/null 2>&1 || continue
        emit kiro "${sess}messages.jsonl"
      done
    fi
    for f in "$HOME/.claude/projects/$(printf '%s' "$dir" | tr -c 'A-Za-z0-9' '-')"/*.jsonl; do
      [ -f "$f" ] && emit claude "$f"
    done
  done <<EOF
$DIRS
EOF
}

collect | sort -t "$(printf '\t')" -k3,3 -u | sort -rn | head -n "$LIMIT" |
  while IFS="$(printf '\t')" read -r m harness path; do
    printf '%-6s  %s  %s\n' "$harness" "$(utc_minute "$m")" "$path"
  done
exit 0
