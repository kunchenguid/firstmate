#!/usr/bin/env bash
# Remove recognized agent Co-authored-by trailers from one Git commit message.
# Usage: fm-commit-msg-sanitize.sh <commit-message-file>
#
# This is a commit-msg hook payload installed only through a Firstmate worker
# launch.  Every verified worker harness receives that same relay, while this
# evidence-bound catalog preserves every line except an exact recognized agent
# identity: Cursor <cursoragent@cursor.com>, Codex <codex@openai.com>, Claude
# Code <claude-code@anthropic.com>, Kimi Code <kimi-code@moonshot.cn>, Grok
# Code <grok-code@x.ai>, or OpenCode <opencode@sst.dev>.  Matching both name
# and address avoids removing a human co-author who merely shares an
# agent-like name, and no Pi signature is inferred without trailer evidence.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

[ "${1:-}" != --help ] || {
  usage
  exit 0
}

[ "$#" -eq 1 ] || {
  usage >&2
  exit 2
}

message=$1
[ -f "$message" ] || {
  echo "error: commit message file does not exist: $message" >&2
  exit 2
}

is_recognized_agent_coauthor() {
  local line=$1
  shopt -s nocasematch
  case "$line" in
    Co-authored-by:[[:space:]]*Cursor[[:space:]]*\<cursoragent@cursor.com\>) ;;
    Co-authored-by:[[:space:]]*Codex[[:space:]]*\<codex@openai.com\>) ;;
    Co-authored-by:[[:space:]]*Claude[[:space:]]Code[[:space:]]*\<claude-code@anthropic.com\>) ;;
    Co-authored-by:[[:space:]]*Kimi[[:space:]]Code[[:space:]]*\<kimi-code@moonshot.cn\>) ;;
    Co-authored-by:[[:space:]]*Grok[[:space:]]Code[[:space:]]*\<grok-code@x.ai\>) ;;
    Co-authored-by:[[:space:]]*OpenCode[[:space:]]*\<opencode@sst.dev\>) ;;
    *)
      shopt -u nocasematch
      return 1
      ;;
  esac
  shopt -u nocasematch
  return 0
}

tmp=$(mktemp "${message}.firstmate.XXXXXX") || exit 1
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT HUP INT TERM

while IFS= read -r line || [ -n "$line" ]; do
  is_recognized_agent_coauthor "$line" && continue
  printf '%s\n' "$line" >> "$tmp"
done < "$message"

mv "$tmp" "$message"
trap - EXIT HUP INT TERM
