#!/usr/bin/env bash
# fm-learnings-search.sh - surface the captain's gstack learnings for a task.
#
# Crewmate workers run in isolated worktrees and never see the gstack
# SessionStart hooks that surface relevant learnings in the captain's own
# sessions, so the start half of that feature belongs in the written brief.
# This helper is that start half: bin/fm-brief.sh derives topic tokens from
# the task id and repo name, passes each token as its own argument, and embeds
# the top hits as a short "Relevant project learnings" section.
#
# The search runs the gstack CLI's learnings searcher at
# $HOME/.claude/skills/gstack/bin/gstack-learnings-search (override with
# FM_GSTACK_SEARCH_BIN). That script resolves its project scope from the cwd
# slug and honors GSTACK_PROJECT_SLUG and GSTACK_HOME, matches any query token
# (token-OR) against learning keys, insights, and file paths, and caps results
# at --limit.
#
# Fail-soft contract: a missing or non-executable searcher, an empty token
# list, no matching learnings, or a searcher error all print nothing and exit
# 0, so a missing or broken learnings store never fails a brief scaffold.
# Usage: fm-learnings-search.sh [--limit <n>] <token>...
#   --limit <n>  cap the number of learnings returned (default 5)
#   <token>...   search tokens, one per argument; joined into one
#                whitespace-separated query for the searcher
#   --help       print this header
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

LIMIT=5
TOKENS=()
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    LIMIT=$a
    want=
    continue
  fi
  case "$a" in
    --limit) want=1 ;;
    --limit=*) LIMIT=${a#--limit=} ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "error: unknown option: $a" >&2; exit 2 ;;
    *) TOKENS+=("$a") ;;
  esac
done
[ -z "$want" ] || { echo "error: --limit requires a value" >&2; exit 2; }
case "$LIMIT" in
  ''|*[!0-9]*) echo "error: --limit must be a positive integer: $LIMIT" >&2; exit 2 ;;
esac
[ "$LIMIT" -gt 0 ] || { echo "error: --limit must be a positive integer: $LIMIT" >&2; exit 2; }

# No tokens means no query: print nothing and let the brief omit the section.
[ "${#TOKENS[@]}" -gt 0 ] || exit 0

SEARCHER=${FM_GSTACK_SEARCH_BIN:-"$HOME/.claude/skills/gstack/bin/gstack-learnings-search"}
[ -x "$SEARCHER" ] || exit 0

# The searcher takes one --query value and token-ORs its whitespace-separated
# words, so join the caller's argv tokens into a single query string.
QUERY=
for t in "${TOKENS[@]}"; do
  QUERY="${QUERY:+$QUERY }$t"
done

# A non-zero searcher exit is absorbed, never propagated: the brief must not
# fail because the learnings store errored.
OUTPUT=$("$SEARCHER" --query "$QUERY" --limit "$LIMIT" 2>/dev/null) || OUTPUT=
[ -n "$OUTPUT" ] || exit 0
printf '%s\n' "$OUTPUT"
