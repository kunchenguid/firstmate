#!/usr/bin/env bash
# fm-chat-question.sh - the durable record of a question firstmate asked the
# captain in chat that is still unanswered.
#
# Usage:
#   fm-chat-question.sh open <key> <summary>   record a question just asked
#   fm-chat-question.sh close <key>            remove it once it is answered
#
# A question asked only in chat, with no backlog hold or other durable record
# behind it, lives in the current conversation alone; a fresh conversation
# would lose it. Firstmate opens a record in the same turn it asks such a
# question and closes it in the turn the captain answers, so the question is
# known without reading anyone's prose. The daily fresh start
# (bin/fm-fresh-start-lib.sh "THE GATE") waits while any record is open, and
# names the first one. A question already behind a captain hold or another
# record reprinted at session start needs no record here.
#
# THE RECORD. One file per question, state/chat-questions/<key>.question,
# holding
#   asked=<epoch>
#   summary=<one line naming the question>
# <key> is 1 to 64 letters, digits, dot, underscore, or hyphen, not starting
# with a dot. Opening an open key again replaces its record. Tabs and newlines
# in the summary become spaces.
#
# Exit codes: 0 done, 1 close found no open question with that key or a write
# failed, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DIR=$STATE/chat-questions

usage() {
  echo "usage: fm-chat-question.sh open <key> <summary> | close <key>" >&2
  exit 2
}

valid_key() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

case "${1:-}" in
open)
  [ "$#" -eq 3 ] || usage
  valid_key "$2" || usage
  summary=$(printf '%s' "$3" | LC_ALL=C tr '\t\r\n' '   ' | sed 's/^ *//; s/ *$//')
  [ -n "$summary" ] || usage
  mkdir -p "$DIR" || exit 1
  tmp=$(mktemp "$DIR/.question.XXXXXX") || exit 1
  if printf 'asked=%s\nsummary=%s\n' "$(date +%s)" "$summary" >"$tmp" && mv -f "$tmp" "$DIR/$2.question"; then
    echo "fm-chat-question: recorded open question $2; close it when the captain answers"
    exit 0
  fi
  rm -f "$tmp"
  exit 1
  ;;
close)
  [ "$#" -eq 2 ] || usage
  valid_key "$2" || usage
  if [ ! -e "$DIR/$2.question" ] && [ ! -L "$DIR/$2.question" ]; then
    echo "fm-chat-question: no open question $2" >&2
    exit 1
  fi
  rm -f "$DIR/$2.question" || exit 1
  echo "fm-chat-question: closed question $2"
  ;;
*) usage ;;
esac
