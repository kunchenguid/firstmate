#!/usr/bin/env bash
# fm-quota-wait.sh - durable registry of crewmate work parked ONLY on a harness
# 5h/quota limit, so a lightweight heartbeat can resume it the moment capacity
# returns instead of the wait rotting invisibly.
#
# One entry per task lives at $FM_HOME/state/<id>.quota-wait as compact JSON, the
# same single-link, colocated convention as <id>.meta/<id>.status. The entry
# records everything needed to relaunch the SAME queued work without re-deriving
# it: the vendor whose limit blocked it, the optional general window, and a
# free-form relaunch instruction (a fm-send steer, a spawn, a promote - whatever
# resumes it). Backoff is stored, not slept, so nothing here busy-polls: the
# heartbeat cadence is the only clock, and each due re-check either resumes or
# pushes next_check out with bounded exponential backoff.
#
# This script is pure registry CRUD. Capacity is judged by the consumer
# (bin/fm-heartbeat.sh) so quota-axi evaluation lives in exactly one place.
#
# Provider-detection limitation: firstmate cannot itself prove a pane is blocked
# SOLELY by a quota limit; the caller classifies that (from the crewmate's
# `paused:` reason) and records it here. A wrong vendor or a non-quota block
# recorded here only costs an extra harmless heartbeat re-check; it is never
# silently dropped.
#
# Usage:
#   fm-quota-wait.sh record <id> --vendor <v> [--window <w>] [--relaunch <str>]
#                               [--wait-secs <n> | --wait-until <epoch>]
#   fm-quota-wait.sh list                     one line per entry: <id> <vendor> <window> next=<epoch> attempts=<n>
#   fm-quota-wait.sh due [--now <epoch>]      ids whose next_check has passed
#   fm-quota-wait.sh get <id>                 print the entry JSON
#   fm-quota-wait.sh bump <id>                one more attempt; push next_check out with bounded backoff
#   fm-quota-wait.sh clear <id>               remove the entry (resumed or abandoned by decision)
#
# FM_QUOTA_WAIT_BASE_SECS   first/base backoff step (default 300, one heartbeat).
# FM_QUOTA_WAIT_MAX_SECS    backoff ceiling (default 3600).
# FM_QUOTA_WAIT_NOW         override "now" epoch for deterministic tests.
# FM_STATE_OVERRIDE         state dir (default $FM_HOME/state).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

BASE_SECS=${FM_QUOTA_WAIT_BASE_SECS:-300}
MAX_SECS=${FM_QUOTA_WAIT_MAX_SECS:-3600}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

now_epoch() {
  if [ -n "${FM_QUOTA_WAIT_NOW:-}" ]; then
    printf '%s\n' "$FM_QUOTA_WAIT_NOW"
  else
    date +%s
  fi
}

entry_path() {  # <id>
  printf '%s/%s.quota-wait\n' "$STATE" "$1"
}

valid_id() {  # <id>
  case "$1" in
    ''|*/*|.|..) return 1 ;;
    *) return 0 ;;
  esac
}

# next_check = now + min(BASE * 2^attempts, MAX), clamped so a bad env never
# yields a negative or runaway step.
backoff_next() {  # <attempts>
  local attempts=$1 step=$BASE_SECS i
  [ "$step" -ge 1 ] 2>/dev/null || step=300
  i=0
  while [ "$i" -lt "$attempts" ]; do
    step=$(( step * 2 ))
    if [ "$step" -ge "$MAX_SECS" ]; then step=$MAX_SECS; break; fi
    i=$(( i + 1 ))
  done
  [ "$step" -le "$MAX_SECS" ] || step=$MAX_SECS
  printf '%s\n' "$(( $(now_epoch) + step ))"
}

cmd_record() {
  local id=${1:-}; shift || true
  valid_id "$id" || { echo "error: record needs a valid task id" >&2; exit 2; }
  local vendor="" window="" relaunch="" wait_secs="" wait_until=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --vendor) vendor=${2:-}; shift 2 ;;
      --window) window=${2:-}; shift 2 ;;
      --relaunch) relaunch=${2:-}; shift 2 ;;
      --wait-secs) wait_secs=${2:-}; shift 2 ;;
      --wait-until) wait_until=${2:-}; shift 2 ;;
      *) echo "error: unknown record option $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$vendor" ] || { echo "error: --vendor is required" >&2; exit 2; }

  local now next
  now=$(now_epoch)
  if [ -n "$wait_until" ]; then
    next=$wait_until
  elif [ -n "$wait_secs" ]; then
    next=$(( now + wait_secs ))
  else
    next=$now
  fi

  mkdir -p "$STATE"
  local tmp
  tmp=$(mktemp "$STATE/.quota-wait.XXXXXX") || { echo "error: mktemp failed" >&2; exit 1; }
  jq -nc \
    --arg id "$id" --arg vendor "$vendor" --arg window "$window" \
    --arg relaunch "$relaunch" --argjson recorded "$now" \
    --argjson wait_until "${wait_until:-0}" --argjson next "$next" '
    {
      id: $id,
      vendor: $vendor,
      window: (if $window == "" then null else $window end),
      relaunch: (if $relaunch == "" then null else $relaunch end),
      recorded_at: $recorded,
      wait_until: (if $wait_until == 0 then null else $wait_until end),
      attempts: 0,
      next_check: $next
    }' > "$tmp" || { rm -f "$tmp"; echo "error: could not compose entry" >&2; exit 1; }
  mv -f "$tmp" "$(entry_path "$id")"
  printf 'recorded quota-wait %s vendor=%s next=%s\n' "$id" "$vendor" "$next"
}

cmd_list() {
  local f
  for f in "$STATE"/*.quota-wait; do
    [ -e "$f" ] || continue
    jq -r '"\(.id) \(.vendor) \(.window // "-") next=\(.next_check) attempts=\(.attempts)"' "$f" 2>/dev/null || true
  done
}

cmd_due() {
  local now=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now) now=${2:-}; shift 2 ;;
      *) echo "error: unknown due option $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$now" ] || now=$(now_epoch)
  local f
  for f in "$STATE"/*.quota-wait; do
    [ -e "$f" ] || continue
    jq -r --argjson now "$now" 'select(.next_check <= $now) | .id' "$f" 2>/dev/null || true
  done
}

cmd_get() {
  local id=${1:-}
  valid_id "$id" || { echo "error: get needs a valid task id" >&2; exit 2; }
  local f
  f=$(entry_path "$id")
  [ -e "$f" ] || { echo "error: no quota-wait entry for $id" >&2; exit 1; }
  cat "$f"
}

cmd_bump() {
  local id=${1:-}
  valid_id "$id" || { echo "error: bump needs a valid task id" >&2; exit 2; }
  local f attempts next tmp
  f=$(entry_path "$id")
  [ -e "$f" ] || { echo "error: no quota-wait entry for $id" >&2; exit 1; }
  attempts=$(jq -r '.attempts' "$f" 2>/dev/null || echo 0)
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  attempts=$(( attempts + 1 ))
  next=$(backoff_next "$attempts")
  tmp=$(mktemp "$STATE/.quota-wait.XXXXXX") || { echo "error: mktemp failed" >&2; exit 1; }
  jq -c --argjson attempts "$attempts" --argjson next "$next" \
    '.attempts = $attempts | .next_check = $next' "$f" > "$tmp" \
    || { rm -f "$tmp"; echo "error: could not update entry" >&2; exit 1; }
  mv -f "$tmp" "$f"
  printf 'bumped %s attempts=%s next=%s\n' "$id" "$attempts" "$next"
}

cmd_clear() {
  local id=${1:-}
  valid_id "$id" || { echo "error: clear needs a valid task id" >&2; exit 2; }
  rm -f "$(entry_path "$id")"
  printf 'cleared quota-wait %s\n' "$id"
}

case "${1:-}" in
  record) shift; cmd_record "$@" ;;
  list) shift; cmd_list "$@" ;;
  due) shift; cmd_due "$@" ;;
  get) shift; cmd_get "$@" ;;
  bump) shift; cmd_bump "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
