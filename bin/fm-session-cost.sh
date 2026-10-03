#!/usr/bin/env bash
# fm-session-cost.sh - read a worker's context size and idle time from its
# harness transcript, and surface a large or cold session once so firstmate
# can start a fresh worker with a handoff note instead of continuing it.
#
# Usage:
#   fm-session-cost.sh show [--json] <task-id>
#   fm-session-cost.sh show --json --all
#   fm-session-cost.sh scan
#
# Why: every turn of a session re-reads its whole context, so a worker's cost
# per turn grows with its context size, and a turn after the provider's prompt
# cache expired re-writes that whole context at full price. A fresh worker in
# the same local copy, started from a short written handoff note, costs a small
# fraction of either. This script is only the measurement and the one-time
# notice; the decision and the handoff procedure belong to the supervisor and
# live in the `session-cache` agent skill, not here.
#
# Opt-in: `scan` is a silent no-op unless config/session-cache exists (absent
# means off). `show` measures on explicit request even without the file, using
# the defaults below for its advice.
#
# config/session-cache holds optional `key=value` lines; blank lines and lines
# starting with `#` are ignored, and an empty file enables every default:
#   fresh_tokens=300000     advise fresh at or above this context size
#   cold_fresh_tokens=150000 advise fresh at or above this size once the cache
#                           is cold
#   cache_ttl_minutes=60    idle time after which the cache counts as cold
#   min_idle_minutes=5      `scan` only surfaces a worker idle at least this
#                           long, so a notice lands between turns, not mid-turn
# Every value is a positive whole number. An unknown key or an invalid value
# makes both subcommands exit 2 with the offending line on stderr.
#
# Measurement (Claude workers only; other harnesses report
# `status=unsupported`): the transcript is the one
# ~/.claude/projects/<dir>/*.jsonl, where <dir> is the worker's recorded
# worktree path with every character outside [A-Za-z0-9] replaced by `-`,
# modified no earlier than the task's current spawn_gen incarnation, so a
# reused local copy or a relaunch never reads a previous session. The task
# record names no session, so when more than one transcript there was written
# since that incarnation began (another Claude session in the same local copy,
# or a /clear), nothing ties one of them to the worker: that reports
# `status=unknown detail=ambiguous-transcript` rather than guessing.
# ~/.claude is the Claude root the worker launched with: the account pin its
# task record carries (`account=`, see bin/fm-worker-account-lib.sh), where
# `ordinary` means ~/.claude and any other value is the pinned root, or for an
# unpinned worker CLAUDE_CONFIG_DIR, then ~/.claude.
# context_tokens is input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens of the newest main-chain (not sidechain) assistant
# entry carrying usage, skipping Claude's `<synthetic>` entries (API error or
# usage-limit stops), whose zero usage is not the session's real context.
# idle_seconds is the age of the transcript's last write.
# A missing transcript or usage reports `status=unknown` and no advice.
#
# show prints one line (or one JSON object with --json); `show --json --all`
# prints one object mapping every local ship and scout task id to that same
# object, so a caller measuring the whole fleet pays one process:
#   status=ok context_tokens=<n> idle_seconds=<n> cache=<warm|cold> advice=<continue|fresh> reason=<-|size|cold> transcript=<path>
#   status=<unknown|unsupported> detail=<why>
#
# scan visits every local ship and scout record in this home (secondmates and
# remote records are skipped). For each worker whose advice is `fresh`, that
# has been idle at least min_idle_minutes, and whose semantic busy record
# (bin/fm-busy-lib.sh) reads `idle` - its turn ended, so a long tool call that
# writes nothing is not mistaken for idle time - it appends one durable `check`
# wake row whose payload is
#   check: session-cost: <task> context=<n>k idle=<n>m cache=<warm|cold> reason=<size|cold>
# and prints `actionable: <payload>`. A per-task marker
# state/.session-cost-<task> records the transcript and reason already
# surfaced, so one session crossing one threshold wakes firstmate once; a new
# reason (a cold mid-size session that grows past fresh_tokens) or a new
# transcript (a relaunch) surfaces again, while a size notice already covers
# that session going cold. Markers of tasks with no record are removed.
# FM_SESSION_COST_SECS (default 300) bounds how often scan does any work, via
# the state/.session-cost-scan mtime, so the watcher can call it every poll.
# The whole scan holds state/.session-cost-scan.lock, so two concurrent scans
# cannot both see a marker absent and queue the same notice twice; a scan that
# cannot take the lock within 10 seconds exits 1 without queueing anything.
# FM_SESSION_COST_NOW overrides the clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/session-cache"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() { printf 'fm-session-cost: %s\n' "$1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-session-cost: jq not found" >&2; exit 1; }

FRESH_TOKENS=300000
COLD_FRESH_TOKENS=150000
CACHE_TTL_MINUTES=60
MIN_IDLE_MINUTES=5

load_config() {
  local line key value
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$line" in *=*) ;; *) die_usage "config/session-cache: not key=value: $line" ;; esac
    case "$value" in ''|*[!0-9]*|0*) die_usage "config/session-cache: not a positive whole number: $line" ;; esac
    case "$key" in
      fresh_tokens) FRESH_TOKENS=$value ;;
      cold_fresh_tokens) COLD_FRESH_TOKENS=$value ;;
      cache_ttl_minutes) CACHE_TTL_MINUTES=$value ;;
      min_idle_minutes) MIN_IDLE_MINUTES=$value ;;
      *) die_usage "config/session-cache: unknown key: $line" ;;
    esac
  done < "$CONFIG_FILE"
}

if [ "$(uname)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

now_epoch() {
  case "${FM_SESSION_COST_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_SESSION_COST_NOW" ;;
  esac
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# The epoch of the task's current incarnation: spawn_gen=s<epoch>.<...>.
spawn_epoch() {  # <meta>
  local gen
  gen=$(meta_value "$1" spawn_gen)
  gen=${gen#s}
  gen=${gen%%.*}
  case "$gen" in ''|*[!0-9]*) echo 0 ;; *) echo "$gen" ;; esac
}

# The Claude root the task's worker launched with.
claude_dir() {  # <meta>
  local account
  account=$(meta_value "$1" account)
  case "$account" in
    '') printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    ordinary) printf '%s\n' "$HOME/.claude" ;;
    *) printf '%s\n' "$account" ;;
  esac
}

# The one transcript for <worktree> under <claude-dir> modified at or after
# <since>. Prints it, or nothing and returns 1 when there is none, or prints
# nothing and returns 2 when more than one qualifies.
find_transcript() {  # <claude-dir> <worktree> <since>
  local claude=$1 worktree=$2 since=$3 candidate dir found='' m f seen=''
  for candidate in "$worktree" "$(cd "$worktree" 2>/dev/null && pwd -P)"; do
    [ -n "$candidate" ] || continue
    dir="$claude/projects/$(printf '%s' "$candidate" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
    [ -d "$dir" ] || continue
    case " $seen " in *" $dir "*) continue ;; esac
    seen="$seen $dir"
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] || continue
      m=$(file_mtime "$f") || continue
      [ "$m" -ge "$since" ] || continue
      [ -z "$found" ] || return 2
      found=$f
    done
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Context size of the newest real main-chain assistant entry with usage, or nothing.
context_tokens() {  # <transcript>
  local lines
  for lines in 400 4000; do
    tail -n "$lines" "$1" 2>/dev/null | jq -Rr '
      fromjson? // empty
      | select(.type == "assistant" and (.isSidechain // false) == false)
      | select(.message.model != "<synthetic>")
      | .message.usage // empty
      | select((.input_tokens | type) == "number")
      | (.input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
    ' | tail -n 1 | grep . && return 0
  done
  return 1
}

# Sets M_STATUS M_DETAIL M_CONTEXT M_IDLE M_CACHE M_ADVICE M_REASON M_TRANSCRIPT.
measure() {  # <task-id>
  local id=$1 meta harness worktree since now m rc
  meta="$STATE/$id.meta"
  M_STATUS=unknown M_DETAIL='' M_CONTEXT='' M_IDLE='' M_CACHE='' M_ADVICE='' M_REASON=- M_TRANSCRIPT=''
  if [ ! -f "$meta" ]; then M_DETAIL=no-task-record; return; fi
  harness=$(meta_value "$meta" harness)
  if [ "$harness" != claude ]; then
    M_STATUS=unsupported M_DETAIL="harness-${harness:-unknown}"
    return
  fi
  worktree=$(meta_value "$meta" worktree)
  if [ -z "$worktree" ]; then M_DETAIL=no-worktree; return; fi
  since=$(spawn_epoch "$meta")
  rc=0
  M_TRANSCRIPT=$(find_transcript "$(claude_dir "$meta")" "$worktree" "$since") || rc=$?
  if [ "$rc" -eq 2 ]; then M_DETAIL=ambiguous-transcript; return; fi
  if [ -z "$M_TRANSCRIPT" ]; then M_DETAIL=no-transcript; return; fi
  M_CONTEXT=$(context_tokens "$M_TRANSCRIPT") || true
  if [ -z "$M_CONTEXT" ]; then M_DETAIL=no-usage; return; fi
  now=$(now_epoch)
  m=$(file_mtime "$M_TRANSCRIPT") || m=$now
  M_IDLE=$((now - m))
  [ "$M_IDLE" -ge 0 ] || M_IDLE=0
  if [ "$M_IDLE" -ge $((CACHE_TTL_MINUTES * 60)) ]; then M_CACHE=cold; else M_CACHE=warm; fi
  if [ "$M_CONTEXT" -ge "$FRESH_TOKENS" ]; then
    M_ADVICE=fresh M_REASON=size
  elif [ "$M_CACHE" = cold ] && [ "$M_CONTEXT" -ge "$COLD_FRESH_TOKENS" ]; then
    M_ADVICE=fresh M_REASON=cold
  else
    M_ADVICE='continue'
  fi
  M_STATUS=ok
}

valid_task_id() {
  case "$1" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# One line per measurement: the fields jq turns into the show --json object.
measure_tsv() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$M_STATUS" "$M_DETAIL" "$M_CONTEXT" \
    "$M_IDLE" "$M_CACHE" "$M_ADVICE" "$M_REASON" "$M_TRANSCRIPT"
}

# shellcheck disable=SC2016 # jq, not the shell, reads these variables
MEASURE_JQ='
  def num: if . == "" then null else tonumber end;
  def str: if . == "" or . == "-" then null else . end;
  split("\t") | {key:.[0], value:{status:.[1], detail:(.[2]|str), context_tokens:(.[3]|num),
    idle_seconds:(.[4]|num), cache:(.[5]|str), advice:(.[6]|str),
    reason:(.[7]|str), transcript:(.[8]|str)}}'

# True for a local ship or scout record: the tasks scan and --all measure.
local_worker() {  # <meta>
  local kind
  kind=$(meta_value "$1" kind)
  case "${kind:-ship}" in ship|scout) ;; *) return 1 ;; esac
  [ -z "$(meta_value "$1" remote_host)" ]
}

cmd_show() {
  local json=0 id meta
  if [ "${1:-}" = --json ]; then json=1; shift; fi
  if [ "$json" -eq 1 ] && [ $# -eq 1 ] && [ "$1" = --all ]; then
    load_config
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      valid_task_id "$id" || continue
      local_worker "$meta" || continue
      measure "$id"
      measure_tsv "$id"
    done | jq -Rc "$MEASURE_JQ" | jq -cs 'from_entries'
    return
  fi
  [ $# -eq 1 ] || die_usage "usage: fm-session-cost.sh show [--json] <task-id> | show --json --all"
  id=$1
  valid_task_id "$id" || die_usage "invalid task id: $id"
  load_config
  measure "$id"
  if [ "$json" -eq 1 ]; then
    measure_tsv "$id" | jq -Rc "$MEASURE_JQ | .value"
  elif [ "$M_STATUS" = ok ]; then
    printf 'status=ok context_tokens=%s idle_seconds=%s cache=%s advice=%s reason=%s transcript=%s\n' \
      "$M_CONTEXT" "$M_IDLE" "$M_CACHE" "$M_ADVICE" "$M_REASON" "$M_TRANSCRIPT"
  else
    printf 'status=%s detail=%s\n' "$M_STATUS" "$M_DETAIL"
  fi
}

cmd_scan() {
  local lock rc=0
  [ $# -eq 0 ] || die_usage "usage: fm-session-cost.sh scan"
  [ -e "$CONFIG_FILE" ] || return 0
  load_config
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  lock="$STATE/.session-cost-scan.lock"
  fm_lock_acquire_wait_max "$lock" 10 || return 1
  scan_locked || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

scan_locked() {
  local marker meta id fingerprint payload now last busy
  now=$(now_epoch)
  last=$(file_mtime "$STATE/.session-cost-scan" 2>/dev/null || echo 0)
  [ $((now - last)) -ge "${FM_SESSION_COST_SECS:-300}" ] || return 0
  touch "$STATE/.session-cost-scan"

  for marker in "$STATE"/.session-cost-*; do
    [ -f "$marker" ] || continue
    id=${marker#"$STATE"/.session-cost-}
    case "$id" in scan|scan.*) continue ;; esac
    [ -f "$STATE/$id.meta" ] || rm -f "$marker"
  done

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_task_id "$id" || continue
    local_worker "$meta" || continue
    measure "$id"
    [ "$M_STATUS" = ok ] && [ "$M_ADVICE" = fresh ] || continue
    [ "$M_IDLE" -ge $((MIN_IDLE_MINUTES * 60)) ] || continue
    busy=$(fm_busy_record_read "$STATE" "$id") || continue
    [ "${busy%% *}" = idle ] || continue
    fingerprint="$M_TRANSCRIPT $M_REASON"
    [ "$(cat "$STATE/.session-cost-$id" 2>/dev/null)" = "$fingerprint" ] && continue
    payload="check: session-cost: $id context=$((M_CONTEXT / 1000))k idle=$((M_IDLE / 60))m cache=$M_CACHE reason=$M_REASON"
    fm_wake_append check "session-cost:$id" "$payload" || return 1
    printf '%s\n' "$fingerprint" > "$STATE/.session-cost-$id"
    printf 'actionable: %s\n' "$payload"
  done
}

case "${1:-}" in
  show) shift; cmd_show "$@" ;;
  scan) shift; cmd_scan "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
