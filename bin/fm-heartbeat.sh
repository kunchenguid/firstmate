#!/usr/bin/env bash
# fm-heartbeat.sh - the token-light five-minute supervision heartbeat.
#
# This is the cheap pass firstmate runs on each heartbeat wake BEFORE (or instead
# of) any broad fleet review. It reads only durable, actionable signals - the
# watcher lock and the quota-wait registry - never captures panes, polls forges,
# or re-reads the whole fleet. It prints one short line per actionable finding and
# NOTHING when the fleet cannot advance, so an idle heartbeat costs almost no
# tokens. It is idempotent and lock-free (it holds no fleet lock), so it is safe
# to run repeatedly and from any session.
#
# It does two things:
#
#   1. Recover a provably-stale watcher lock. If this home's watcher lock is
#      unhealthy AND its recorded holder pid is not alive, the lock is cleared so
#      the next arm can own a fresh cycle, and "re-arm supervision" is surfaced.
#      It fails closed: a live holder (even a wedged one) is the guard/daemon's
#      concern and is never force-unlocked here.
#
#   2. Resume quota-parked work. For each bin/fm-quota-wait.sh entry whose backoff
#      window has passed, re-check availability (quota-axi general windows, the
#      same signal bin/fm-dispatch-select.sh uses). When capacity is back it
#      surfaces a "resume <id>" next step and leaves the entry due so it keeps
#      re-surfacing until firstmate relaunches and clears it - it is never
#      silently abandoned. When still constrained it pushes the entry out with
#      bounded backoff, so nothing here busy-polls.
#
# Provider-detection limitation: quota-axi reports GENERAL windows only for claude
# (five_hour, seven_day) and codex (five_hour, weekly). For any other vendor, or
# when quota-axi is missing or returns unparseable JSON, capacity cannot be
# verified; the heartbeat falls back to the entry's recorded reset time
# (--wait-until) and, absent that, keeps backing off rather than abandoning or
# busy-polling.
#
# Usage:
#   fm-heartbeat.sh [--quota-json <file>] [--now <epoch>]
#
# FM_GUARD_GRACE               watcher-liveness beacon freshness (default 300).
# FM_QUOTA_WAIT_MIN_REMAINING  percentRemaining at/above which a vendor counts as
#                              recovered (default 5).
# FM_HEARTBEAT_QUOTA_AXI / FM_DISPATCH_QUOTA_AXI  override the quota command.
# --quota-json / --now         test seams (fixture quota JSON; fixed clock).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
QUOTA_WAIT="$SCRIPT_DIR/fm-quota-wait.sh"
GRACE=${FM_GUARD_GRACE:-300}
MIN_REMAINING=${FM_QUOTA_WAIT_MIN_REMAINING:-5}
QUOTA_AXI=${FM_HEARTBEAT_QUOTA_AXI:-${FM_DISPATCH_QUOTA_AXI:-quota-axi}}

QUOTA_JSON_FILE=
NOW_OVERRIDE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quota-json) QUOTA_JSON_FILE=${2:-}; shift 2 ;;
    --now) NOW_OVERRIDE=${2:-}; shift 2 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0" >&2
      exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

now_epoch() {
  if [ -n "$NOW_OVERRIDE" ]; then printf '%s\n' "$NOW_OVERRIDE"; else date +%s; fi
}

# --- 1. stale watcher-lock recovery -----------------------------------------

recover_stale_watcher_lock() {
  local lockdir="$STATE/.watch.lock" lock_pid
  [ -e "$lockdir" ] || return 0
  # A genuinely live, identity-matched, freshly-beating watcher is healthy: leave it.
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0
  lock_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  # Fail closed: only clear a lock whose recorded holder is PROVABLY not alive.
  if [ -n "$lock_pid" ] && fm_pid_alive "$lock_pid"; then
    return 0
  fi
  fm_lock_remove_path "$lockdir" 2>/dev/null || fm_lock_clean_known_files "$lockdir"
  printf 'watcher: cleared stale lock (holder pid %s not alive); re-arm supervision\n' "${lock_pid:-none}"
}

# --- 2. quota-wait resume ----------------------------------------------------

# General (non-model) windows that gate whole-vendor availability, mirroring
# bin/fm-dispatch-select.sh's quota-balanced contract. A jq fragment, so the
# unexpanded $v is intentional.
# shellcheck disable=SC2016
general_ids_jq='
  def general_ids($v):
    if $v == "claude" then ["five_hour","seven_day"]
    elif $v == "codex" then ["five_hour","weekly"]
    else [] end;'

# Load the quota snapshot once. Empty on any trouble - callers then fall back to
# the recorded reset time instead of guessing.
load_quota_json() {
  if [ -n "$QUOTA_JSON_FILE" ]; then
    cat "$QUOTA_JSON_FILE" 2>/dev/null || true
    return 0
  fi
  command -v "$QUOTA_AXI" >/dev/null 2>&1 || return 0
  "$QUOTA_AXI" --json 2>/dev/null || true
}

# Echo the min percentRemaining across a vendor's general windows (optionally a
# single named window), or nothing if the snapshot is unusable or has no windows.
quota_min_remaining() {  # <quota_json> <vendor> <window-or-empty>
  local quota_json=$1 vendor=$2 window=$3
  printf '%s\n' "$quota_json" | jq -er --arg v "$vendor" --arg w "$window" "
    $general_ids_jq
    (if \$w == \"\" then general_ids(\$v) else [\$w] end) as \$ids
    | [ (.providers // [])[]? | select(.provider == \$v)
        | (.windows // [])[]?
        | . as \$win
        | select( (\$ids | index(\$win.id)) != null
                  and ((\$win.kind? // \"\") != \"model\")
                  and ((\$win.percentRemaining? | type) == \"number\") )
        | \$win.percentRemaining ]
    | if length == 0 then error(\"none\") else min end
  " 2>/dev/null
}

resume_quota_waits() {
  local now quota_json due id entry vendor window relaunch wait_until min available
  now=$(now_epoch)
  quota_json=$(load_quota_json)
  due=$("$QUOTA_WAIT" due --now "$now" 2>/dev/null) || return 0
  [ -n "$due" ] || return 0

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    entry=$("$QUOTA_WAIT" get "$id" 2>/dev/null) || continue
    vendor=$(printf '%s' "$entry" | jq -r '.vendor // ""')
    window=$(printf '%s' "$entry" | jq -r '.window // ""')
    relaunch=$(printf '%s' "$entry" | jq -r '.relaunch // "no relaunch instruction recorded"')
    wait_until=$(printf '%s' "$entry" | jq -r '.wait_until // ""')

    available=0
    min=
    if [ -n "$quota_json" ]; then
      min=$(quota_min_remaining "$quota_json" "$vendor" "$window" || true)
    fi
    if [ -n "$min" ]; then
      # Capacity-verified: a real percentRemaining at/above the floor.
      if awk -v m="$min" -v t="$MIN_REMAINING" 'BEGIN{exit !(m+0 >= t+0)}'; then
        available=1
      fi
    else
      # No usable quota signal (unknown vendor, or quota-axi absent/unparseable):
      # fall back to the recorded reset time.
      case "$wait_until" in
        ''|null) : ;;
        *) [ "$now" -ge "$wait_until" ] 2>/dev/null && available=1 ;;
      esac
    fi

    if [ "$available" -eq 1 ]; then
      if [ -n "$min" ]; then
        printf 'resume %s: %s capacity available (%s%% remaining); relaunch: %s\n' \
          "$id" "$vendor" "$min" "$relaunch"
      else
        printf 'resume %s: %s wait window elapsed; relaunch: %s\n' \
          "$id" "$vendor" "$relaunch"
      fi
      # Leave the entry due so it keeps re-surfacing until firstmate relaunches
      # and clears it - never silently dropped.
    else
      # Still constrained: push next_check out with bounded backoff (no busy poll).
      "$QUOTA_WAIT" bump "$id" >/dev/null 2>&1 || true
    fi
  done <<EOF
$due
EOF
}

recover_stale_watcher_lock
resume_quota_waits
exit 0
