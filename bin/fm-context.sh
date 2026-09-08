#!/usr/bin/env bash
# fm-context.sh - how much context window this session and each crew has left.
#
# Why this exists: a session that runs out of context compacts, and a crew that
# compacts mid-task can lose a decision it was told once and then repeat work or
# quietly drop a constraint. The percentage a harness renders in its own status
# line is visible only to whoever is looking at that pane, so it cannot be acted
# on by supervision and it cannot be read for THIS session at all.
#
# The authoritative source is the session transcript, not rendered output. Claude
# Code records exact token usage on every assistant record, so the current
# context is the last such record's input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens. That is a structural fact rather than a vendor string,
# so it does not break when a status line is restyled.
#
# Usage: fm-context.sh [--json] [--window <tokens>] [--threshold <percent>] [<task-id>...]
#   No task ids reports this session plus every task with a state/<id>.meta.
#   --window     context window to measure against (default 1000000).
#   --threshold  exit 1 if any reported session has less than this percent of the
#                window remaining, so a guard can gate on it. Default 0, never fails.
#   --json       one JSON object per line instead of the table.
#
# Both numbers are always printed - used and remaining - because a bare
# percentage is read as either one depending on who is reading it.
#
# LIMITATION, stated rather than hidden: the window is a parameter, not a
# measurement. The transcript records what was consumed, never the model's
# capacity, and it does not record the harness's auto-compact headroom. The
# model name is printed so a wrong --window is visible instead of silent.
set -euo pipefail

FM_HOME="${FM_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECTS_ROOT="${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"

window=1000000
threshold=0
as_json=0
declare -a wanted=()

die() { printf 'fm-context.sh: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1; shift ;;
    --window) [ $# -ge 2 ] || die "--window needs a value"; window="$2"; shift 2 ;;
    --threshold) [ $# -ge 2 ] || die "--threshold needs a value"; threshold="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) wanted+=("$1"); shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
[ "$window" -gt 0 ] 2>/dev/null || die "--window must be a positive integer"

# A transcript lives under a directory named after its working directory with
# every '/' and '.' replaced by '-', so the mapping is derivable rather than
# needing a lookup table.
transcript_dir() {
  printf '%s/%s' "$PROJECTS_ROOT" "$(printf '%s' "$1" | tr './' '--')"
}

# Streams the file and keeps the newest assistant usage, so a large transcript is
# not slurped into memory. Prints "<tokens> <model>" or nothing.
read_usage() {
  local file="$1"
  [ -r "$file" ] || return 0
  jq -rn '
    reduce inputs as $r ([0,"?"];
      if $r.type == "assistant" and ($r.message.usage != null)
      then [ (($r.message.usage.input_tokens // 0)
              + ($r.message.usage.cache_creation_input_tokens // 0)
              + ($r.message.usage.cache_read_input_tokens // 0)),
             ($r.message.model // "?") ]
      else . end)
    | select(.[0] > 0) | "\(.[0]) \(.[1])"
  ' "$file" 2>/dev/null || true
}

# The newest transcript in a directory, used when no session id is known.
newest_transcript() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -1 | cut -d' ' -f2-
}

emit() {
  local label="$1" tokens="$2" model="$3"
  local used_pct left left_pct
  used_pct=$(( tokens * 100 / window ))
  left=$(( window - tokens ))
  [ "$left" -lt 0 ] && left=0
  left_pct=$(( left * 100 / window ))
  if [ "$as_json" = 1 ]; then
    jq -cn --arg label "$label" --arg model "$model" \
      --argjson used "$tokens" --argjson left "$left" \
      --argjson used_pct "$used_pct" --argjson left_pct "$left_pct" \
      --argjson window "$window" \
      '{label:$label, model:$model, window:$window, used:$used,
        used_percent:$used_pct, remaining:$left, remaining_percent:$left_pct}'
  else
    printf '%-30s %9d used (%3d%%)  %9d left (%3d%%)  %s\n' \
      "$label" "$tokens" "$used_pct" "$left" "$left_pct" "$model"
  fi
  if [ "$threshold" -gt 0 ] && [ "$left_pct" -lt "$threshold" ]; then
    return 1
  fi
  return 0
}

breached=0

report_one() {
  local label="$1" file="$2"
  local line
  line=$(read_usage "$file")
  [ -n "$line" ] || return 0
  emit "$label" "${line%% *}" "${line##* }" || breached=1
}

if [ "$as_json" = 0 ]; then
  printf '%-30s %-22s %-22s %s\n' "session" "context" "remaining" "model"
fi

# This session, when its id is known; otherwise the newest transcript for this home.
if [ ${#wanted[@]} -eq 0 ]; then
  self_dir=$(transcript_dir "$FM_HOME")
  self_file=""
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -r "$self_dir/$CLAUDE_CODE_SESSION_ID.jsonl" ]; then
    self_file="$self_dir/$CLAUDE_CODE_SESSION_ID.jsonl"
  else
    self_file=$(newest_transcript "$self_dir")
  fi
  [ -n "$self_file" ] && report_one "this session" "$self_file"
fi

# Crew: each task's worktree is recorded in its metadata, and the worktree maps
# to a transcript directory by the same rule.
shopt -s nullglob
for meta in "$FM_HOME"/state/*.meta; do
  id=$(basename "$meta" .meta)
  if [ ${#wanted[@]} -gt 0 ]; then
    match=0
    for w in "${wanted[@]}"; do [ "$w" = "$id" ] && match=1; done
    [ "$match" = 1 ] || continue
  fi
  worktree=$(sed -n 's/^worktree=//p' "$meta" | head -1)
  [ -n "$worktree" ] || continue
  report_one "$id" "$(newest_transcript "$(transcript_dir "$worktree")")"
done
shopt -u nullglob

exit "$breached"
