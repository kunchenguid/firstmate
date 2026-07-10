#!/usr/bin/env bash
# fm-ctx-hook.sh <turnend-file> <context-file>
#
# Claude Stop-hook helper installed by fm-spawn.sh. Does two things every turn:
#   1. touch <turnend-file>  - preserves the existing turn-end signal the watcher
#      relies on (this REPLACES the bare `touch` the hook used to run).
#   2. record the crewmate's current context size to <context-file> - harness-truth
#      from the transcript, NOT a model self-report. Used by fm-context.sh and the
#      heartbeat fleet review to flag a >=60% context-handoff (see the
#      context-handoff skill).
#
# The Stop hook delivers its payload as JSON on stdin, including .transcript_path.
# <context-file> is state/<id>.context - deliberately NOT a *.status or
# *.turn-ended file, so writing it never trips the watcher's signal scan
# (fm-watch.sh scan_signals globs only *.status and *.turn-ended). Detection is
# therefore silent: it never wakes firstmate on its own.
set -u

TURNEND=${1:?turnend path required}
CTX=${2:?context path required}

# 1. Turn-end signal first, unconditionally - context recording must never be able
#    to swallow the turn-end the watcher needs.
touch "$TURNEND" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
tp=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# Last transcript record carrying usage. tac + head -n1 walks from the end and
# stops at the first (=newest) match, so a large transcript is never fully
# slurped. usage lives at .message.usage on assistant records.
usage=$(tac "$tp" 2>/dev/null \
  | jq -c 'select(.message.usage != null) | .message.usage' 2>/dev/null \
  | head -n1)
[ -n "$usage" ] || exit 0

tokens=$(printf '%s' "$usage" \
  | jq -r '(.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)' 2>/dev/null || true)
case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac

# Atomic-ish write so a monitor never reads a half-written value.
if printf '%s\n' "$tokens" > "$CTX.tmp" 2>/dev/null; then
  mv -f "$CTX.tmp" "$CTX" 2>/dev/null || true
fi
exit 0
