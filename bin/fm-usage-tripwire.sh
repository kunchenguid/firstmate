#!/usr/bin/env bash
# fm-usage-tripwire.sh - fast read-only token-usage watcher check.
#
# Why this exists:
# - 2026-07-06 eval machinery spawned 341 hidden `claude -p` sessions in under an hour, and 307 recorded zero local usage because they were killed mid-stream.
# - 2026-07-04 burned about 8,150 Claude turns and 7.6M output tokens in one day while interactive use was near zero.
# - Session count is therefore a first-class signal, not a proxy for token totals.
#
# Watcher arming:
# - Copy or symlink this script to a standing check path such as `state/usage-tripwire.check.sh`.
# - Example: `ln -sf "$(pwd -P)/bin/fm-usage-tripwire.sh" state/usage-tripwire.check.sh`.
# - The watcher contract is strict: print one alarm line only when firstmate should wake, print nothing when healthy, and finish before `FM_CHECK_TIMEOUT`.
#
# Window and thresholds:
# - `FM_USAGE_WINDOW_MINUTES` defaults to 60 so the watcher can alarm within the hour.
# - `FM_USAGE_SESSION_THRESHOLD` defaults to 50 modified transcript files per window, which is far below the 341-session incident but high enough for normal single-worker churn.
# - `FM_USAGE_OUTPUT_THRESHOLD` defaults to 150000 output tokens per window, which is below the 7.6M/day burn average of about 316k/hour but above normal single-worker output.
#
# Transcript roots:
# - `FM_USAGE_CLAUDE_DIR` defaults to `$HOME/.claude/projects`.
# - `FM_USAGE_CODEX_DIR` defaults to `$HOME/.codex/sessions`.
# - Missing transcript dirs are treated as empty, not as errors.
set -u

usage() {
  cat <<'EOF'
Usage: fm-usage-tripwire.sh [--help]

Read-only watcher check for recent agent usage bursts.

It scans only transcript files whose mtime is inside the sliding window.
It counts modified transcript files as new sessions and sums output tokens in those files.
It prints exactly one alarm line when either threshold is breached.
It prints nothing when healthy.

Environment:
  FM_USAGE_WINDOW_MINUTES       Sliding window in minutes. Default: 60.
  FM_USAGE_SESSION_THRESHOLD    Alarm when recent transcript-file count is above this number. Default: 50.
  FM_USAGE_OUTPUT_THRESHOLD     Alarm when summed recent output tokens is above this number. Default: 150000.
  FM_USAGE_CLAUDE_DIR           Claude transcript root. Default: $HOME/.claude/projects.
  FM_USAGE_CODEX_DIR            Codex transcript root. Default: $HOME/.codex/sessions.

Watcher arming:
  ln -sf "$(pwd -P)/bin/fm-usage-tripwire.sh" state/usage-tripwire.check.sh
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'Usage: fm-usage-tripwire.sh [--help]\n' >&2
    exit 2
    ;;
esac

WINDOW_MINUTES=${FM_USAGE_WINDOW_MINUTES:-60}
SESSION_THRESHOLD=${FM_USAGE_SESSION_THRESHOLD:-50}
OUTPUT_THRESHOLD=${FM_USAGE_OUTPUT_THRESHOLD:-150000}
CLAUDE_DIR=${FM_USAGE_CLAUDE_DIR:-"$HOME/.claude/projects"}
CODEX_DIR=${FM_USAGE_CODEX_DIR:-"$HOME/.codex/sessions"}

is_non_negative_integer() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

if ! is_non_negative_integer "$WINDOW_MINUTES" || [ "$WINDOW_MINUTES" -eq 0 ]; then
  printf 'usage-tripwire: invalid FM_USAGE_WINDOW_MINUTES=%s\n' "$WINDOW_MINUTES"
  exit 0
fi

if ! is_non_negative_integer "$SESSION_THRESHOLD"; then
  printf 'usage-tripwire: invalid FM_USAGE_SESSION_THRESHOLD=%s\n' "$SESSION_THRESHOLD"
  exit 0
fi

if ! is_non_negative_integer "$OUTPUT_THRESHOLD"; then
  printf 'usage-tripwire: invalid FM_USAGE_OUTPUT_THRESHOLD=%s\n' "$OUTPUT_THRESHOLD"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'usage-tripwire: jq missing; cannot evaluate token spike signal\n'
  exit 0
fi

tmp_files=${TMPDIR:-/tmp}/fm-usage-tripwire-files.$$
# shellcheck disable=SC2329
cleanup() {
  rm -f "$tmp_files"
}
trap cleanup EXIT HUP INT TERM
: > "$tmp_files"

collect_recent_files() {
  local root=$1
  [ -d "$root" ] || return 0
  find "$root" -type f -name '*.jsonl' -mmin "-$WINDOW_MINUTES" -print 2>/dev/null || true
}

collect_recent_files "$CLAUDE_DIR" >> "$tmp_files"
collect_recent_files "$CODEX_DIR" >> "$tmp_files"

SESSION_COUNT=$(wc -l < "$tmp_files" | tr -d '[:space:]')

sum_claude_file() {
  local file=$1
  jq -r '
    select(.message.usage? != null)
    | (.message.usage.output_tokens // 0)
  ' "$file" 2>/dev/null \
    | awk '{ sum += $1 } END { printf "%.0f\n", sum + 0 }'
}

sum_codex_file() {
  local file=$1
  jq -r '
    def output_from_token_count:
      if type == "number" then .
      elif type == "object" then
        (.output_tokens // .output // .completion_tokens // .completion // .assistant_tokens // 0)
      else 0
      end;
    if (.type? == "event_msg" and .payload.type? == "token_count") then
      (.payload.info.token_count? // .payload.info? // empty | output_from_token_count)
    elif (.type? == "token_count") then
      (.info.token_count? // .info? // empty | output_from_token_count)
    elif (.token_count? != null) then
      (.token_count | output_from_token_count)
    else
      empty
    end
  ' "$file" 2>/dev/null \
    | awk '{ sum += $1 } END { printf "%.0f\n", sum + 0 }'
}

OUTPUT_TOKENS=0
while IFS= read -r file; do
  case "$file" in
    "$CLAUDE_DIR"/*)
      file_tokens=$(sum_claude_file "$file")
      ;;
    "$CODEX_DIR"/*)
      file_tokens=$(sum_codex_file "$file")
      ;;
    *)
      file_tokens=0
      ;;
  esac
  OUTPUT_TOKENS=$((OUTPUT_TOKENS + file_tokens))
done < "$tmp_files"

session_breach=0
token_breach=0
[ "$SESSION_COUNT" -gt "$SESSION_THRESHOLD" ] && session_breach=1
[ "$OUTPUT_TOKENS" -gt "$OUTPUT_THRESHOLD" ] && token_breach=1

if [ "$session_breach" -eq 1 ] || [ "$token_breach" -eq 1 ]; then
  printf 'usage-tripwire: window=%sm sessions=%s/%s output_tokens=%s/%s breach=' \
    "$WINDOW_MINUTES" "$SESSION_COUNT" "$SESSION_THRESHOLD" "$OUTPUT_TOKENS" "$OUTPUT_THRESHOLD"
  if [ "$session_breach" -eq 1 ] && [ "$token_breach" -eq 1 ]; then
    printf 'sessions,output_tokens\n'
  elif [ "$session_breach" -eq 1 ]; then
    printf 'sessions\n'
  else
    printf 'output_tokens\n'
  fi
fi

exit 0
