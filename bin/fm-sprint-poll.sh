#!/usr/bin/env bash
# One short-poll asking a single question: is it time for the PM to check the
# sprint board?
#
# It does NOT read the board, and cannot. The board lives behind MCP, and MCP
# tools do not exist outside an agent turn - so no script, watcher or cron can
# see it (.agents/skills/notion-board/SKILL.md states this outright). What this
# emits is therefore a SCHEDULING signal, not a content one: "the moment to look
# has arrived", never "a new task exists". The PM reads the board itself, inside
# the turn this wake opens.
#
# Contract, taken verbatim from bin/fm-x-poll.sh, which solves the same shape of
# problem for the relay:
#   output  => the watcher wakes firstmate
#   silence => the fleet keeps sleeping
#
# Inert by default: a HARD no-op (exit 0, no output) unless config/sprint-poll.env
# exists. Until the captain opts in, the watcher must behave exactly as before,
# byte for byte.
#
# Configuration - config/sprint-poll.env, LOCAL and gitignored:
#   FM_SPRINT_INTERVAL  seconds between checks (default 3600)
#   FM_SPRINT_HOURS     local-time working window, "start-end" (default 9-20)
#   FM_SPRINT_DAYS      days of week 1=Mon..7=Sun, "start-end" (default 1-5)
#
# The window exists because every wake costs an agent turn, and a turn spent
# discovering an empty board at 03:00 is pure spend. Defaults give about eleven
# checks on a weekday instead of twenty-four around the clock.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

CONF="$CONFIG/sprint-poll.env"
[ -f "$CONF" ] || exit 0          # inert: not configured, nothing to say

# shellcheck source=/dev/null
. "$CONF" 2>/dev/null || exit 0

INTERVAL=${FM_SPRINT_INTERVAL:-3600}
HOURS=${FM_SPRINT_HOURS:-9-20}
DAYS=${FM_SPRINT_DAYS:-1-5}
case "$INTERVAL" in ''|*[!0-9]*|0*) INTERVAL=3600 ;; esac

in_range() {  # <value> <start-end>
  local v=$1 lo=${2%%-*} hi=${2##*-}
  case "$lo$hi" in ''|*[!0-9]*) return 0 ;; esac   # malformed window never gates
  [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ]
}

in_range "$(date +%u)" "$DAYS" || exit 0
in_range "$(date +%-H)" "$HOURS" || exit 0

STAMP="$STATE/sprint-poll.last"
now=$(date +%s)
last=0
[ ! -f "$STAMP" ] || last=$(tr -d '[:space:]' < "$STAMP" 2>/dev/null)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $(( now - last )) -ge "$INTERVAL" ] || exit 0

# Claim the slot ATOMICALLY before emitting. Two watchers, or a restart racing
# the loop, would otherwise both pass the check above and wake the PM twice for
# one interval - paying for two turns to answer one question.
mkdir -p "$STATE" 2>/dev/null || true
tmp="$STAMP.$$"
printf '%s\n' "$now" > "$tmp" 2>/dev/null || exit 0
mv -f "$tmp" "$STAMP" 2>/dev/null || { rm -f "$tmp"; exit 0; }

printf 'sprint-check\n'
