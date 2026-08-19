#!/usr/bin/env bash
# fm-secondmate-wake-check.sh - does each recorded secondmate still CONSUME its
# own durable wake queue?
#
# Usage:
#   fm-secondmate-wake-check.sh scan [--startup]
#   fm-secondmate-wake-check.sh probe <secondmate-home>
#
# scan   Evaluate every LOCAL kind=secondmate direct report this home records,
#        queue one durable check wake per newly observed stall, and print an
#        "actionable: ..." line for each. At most one evaluation per
#        FM_SECONDMATE_WAKE_SCAN_SECS; --startup is the supported forced
#        evaluation and always runs. Silent and exit 0 when every recorded
#        secondmate is consuming its queue. A remote route, or a home this scan
#        cannot read, is passed over silently rather than judged - see the
#        windows below, and use `probe` to see the exact reason for one home.
# probe  Print one verdict for a single home, with no wake and no cadence:
#        "ok", "stalled <age-seconds> <oldest-sequence>", or "skipped <reason>".
#        Always exits 0; the verdict is the output.
#
# WHY THIS EXISTS, AND WHAT IT ASSERTS
#
# A secondmate is woken by its own watcher, its watcher is armed by its own
# session, and its session runs only when woken. Once that loop stops with a
# wake already queued, nothing inside that home can restart it, because waking
# is precisely what it lost. From outside, the fleet asked only whether an agent
# process existed - and an idle secondmate and a deaf one answer that question
# identically. This asserts the other half: that the home's durable wake queue
# is being consumed.
#
# The signal is the age of the OLDEST unacknowledged row in the secondmate's own
# state/.wake-queue. Each row carries its own append epoch inside the record,
# written once and never rewritten, and a row leaves the queue only through the
# generation-bound acknowledgement that follows handling. So this is positive
# evidence produced by the very mechanism that failed: something needed handling
# and handling did not consume it. An empty queue is a healthy idle mate; an old
# row is a deaf one. That is exactly the distinction the process check cannot
# make, and it is why the two rejected candidates are not used:
#
#   - A stale liveness beacon (state/.last-watcher-beat) is written only while a
#     watcher process runs. A healthy idle home legitimately has no watcher
#     between cycles, and a home that has never armed one has no beacon file at
#     all, so "stale" and "absent" are its normal steady state. Asserting on it
#     reproduces the idle/deaf confusion one level down.
#   - An uncleared state/.watcher-down marker is republished on every watcher
#     close AND every durable queue append, so its mtime tracks the last append
#     rather than the age of the outage, and pending:downtime is its ordinary
#     transient state between a watcher close and the next handling turn. Its
#     generation token carries a timestamp only as an opaque uniqueness
#     component, which docs/watcher-continuity.md deliberately does not promise
#     as a clock.
#
# WHAT THIS IS NOT
#
# It is an adjunct to paths that already run - the watcher's ordinary poll cycle
# and session start - not a daemon, a watcher, or a monitoring service of its
# own. It reads; it never writes into another home, never starts a process, and
# never arms a watcher anywhere. Cross-home arming stays forbidden precisely
# because bin/fm-watch-arm.sh is single-home by design. Recovery is firstmate's:
# nudging the secondmate through its own endpoint makes that secondmate's own
# session take a turn and arm its own watcher.
#
# WINDOWS THIS DOES NOT CLOSE
#
#   - It detects a wake loop that received work and did not consume it. A dead
#     wake loop in a home where nothing appends to the queue produces no row and
#     no finding.
#   - A remote secondmate's home lives on another machine, so its queue is not
#     locally readable at all. `scan` passes those routes over; it never claims
#     them healthy, but it does not cover them either, and nothing else does.
#   - Detection is bounded, not immediate: up to the stall bound plus one scan
#     interval. This turns a permanent outage into a delayed one.
#   - It proves the queue is not draining. It does not prove why.
#
# It also does not restart that home's own intake. A registered long-polling
# source is re-armed by its home's own `bin/fm-procevent.sh reconcile`, which
# runs from that home's watcher - the very thing that stopped - so a deaf home's
# intake stays down until its wake loop is restored. That is why the two halves
# are separate: `reconcile` recovers intake without waiting for a handler, and
# this recovers a home where `reconcile` is not running at all. Neither assumes
# the other.
#
# It takes no lock in the secondmate's home: acquiring another home's wake-queue
# lock would both write into that home and let a wedged foreign lock stall this
# scan. Reading unlocked is safe for this verdict because appends only ever add
# a row at the end, so a partially written newest row cannot change which row is
# oldest; malformed rows are ignored.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SCAN_MARKER="$STATE/.secondmate-wake-scan"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Print the whole leading comment block, derived from the file rather than a
# fixed line range so extending the header cannot silently truncate the help.
header() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }
usage() { header >&2; exit 2; }

bounded_setting() {  # <name> <value> <min> <max>
  local name=$1 value=$2 min=$3 max=$4
  case "$value" in
    ''|*[!0-9]*)
      printf 'fm-secondmate-wake-check: %s must be a whole number from %s to %s\n' "$name" "$min" "$max" >&2
      exit 2
      ;;
  esac
  if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    printf 'fm-secondmate-wake-check: %s must be a whole number from %s to %s\n' "$name" "$min" "$max" >&2
    exit 2
  fi
}

# How long an unconsumed row may legitimately sit. A secondmate can hold one row
# for the length of a single long turn, so the default is generous: this exists
# to catch an outage measured in hours, not to police a slow turn.
STALL_SECS=${FM_SECONDMATE_WAKE_STALL_SECS:-1800}
bounded_setting FM_SECONDMATE_WAKE_STALL_SECS "$STALL_SECS" 300 86400
SCAN_SECS=${FM_SECONDMATE_WAKE_SCAN_SECS:-300}
bounded_setting FM_SECONDMATE_WAKE_SCAN_SECS "$SCAN_SECS" 60 3600

now_epoch() {
  case "${FM_SECONDMATE_WAKE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_SECONDMATE_WAKE_NOW" ;;
  esac
}

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# The oldest still-queued row, as "<epoch> <sequence>". Rows that do not carry a
# numeric epoch and sequence are ignored rather than guessed at, and the oldest
# is chosen by sequence because the queue's sequence is the monotonic identity
# its acknowledgement consumes.
oldest_queued_row() {  # <queue-file>
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (!found || $2 + 0 < seq + 0) { found = 1; epoch = $1; seq = $2 }
    }
    END { if (found) printf "%s %s\n", epoch, seq }
  ' "$1" 2>/dev/null
}

cmd_probe() {  # <secondmate-home>
  local home=${1:-} queue row epoch seq now age
  case "$home" in
    /*) ;;
    *) printf 'skipped recorded home is not an absolute path\n'; return 0 ;;
  esac
  [ -d "$home" ] && [ ! -L "$home" ] || { printf 'skipped recorded home is not a readable directory\n'; return 0; }
  queue="$home/state/.wake-queue"
  [ -e "$queue" ] || { printf 'ok\n'; return 0; }
  [ -f "$queue" ] && [ ! -L "$queue" ] || { printf 'skipped wake queue is not a regular file\n'; return 0; }
  [ -r "$queue" ] || { printf 'skipped wake queue is not readable from here\n'; return 0; }
  row=$(oldest_queued_row "$queue")
  [ -n "$row" ] || { printf 'ok\n'; return 0; }
  epoch=${row%% *}
  seq=${row##* }
  now=$(now_epoch)
  age=0
  [ "$now" -le "$epoch" ] || age=$((now - epoch))
  if [ "$age" -ge "$STALL_SECS" ]; then
    printf 'stalled %s %s\n' "$age" "$seq"
  else
    printf 'ok\n'
  fi
}

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# A wake key stays queued exactly while its record is unacknowledged, so the
# durable queue is the dedup: a stall reports once and stays quiet until the
# supervisor has actually handled and acknowledged it.
queue_key_exists() {  # <key>
  fm_wake_queued_keys check 2>/dev/null | grep -Fxq -- "$1"
}

scan_marker_age() {
  local now m
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || { printf '999999\n'; return; }
  now=$(now_epoch)
  m=$(file_mtime "$SCAN_MARKER")
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  if [ "$now" -lt "$m" ]; then printf '0\n'; else printf '%s\n' $((now - m)); fi
}

write_scan_marker() {
  local tmp
  tmp=$(mktemp "$SCAN_MARKER.XXXXXX") || return 1
  printf 'epoch=%s\n' "$(now_epoch)" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$SCAN_MARKER" || { rm -f "$tmp"; return 1; }
}

is_secondmate_meta() {  # <meta>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  grep -q '^kind=secondmate$' "$1" 2>/dev/null
}

any_secondmate() {
  local meta
  for meta in "$STATE"/*.meta; do
    is_secondmate_meta "$meta" && return 0
  done
  return 1
}

cmd_scan() {
  local startup=0 meta id home remote verdict age seq key payload status=0
  case "${1:-}" in
    '') ;;
    --startup) startup=1 ;;
    *) usage ;;
  esac
  [ "$#" -le 1 ] || usage
  [ -d "$STATE" ] || return 0
  # A home with no recorded secondmate has nothing to ask about, so it stays a
  # true no-op: no cadence marker, no generated state, nothing to clean up. A
  # secondmate home naturally lands here too, since it records none of its own.
  any_secondmate || return 0
  if [ "$startup" -eq 0 ] && [ "$(scan_marker_age)" -lt "$SCAN_SECS" ]; then
    return 0
  fi
  for meta in "$STATE"/*.meta; do
    is_secondmate_meta "$meta" || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    # A remote route's home is on another machine; report it as uncovered rather
    # than resolving its path against this filesystem, where it may not exist or
    # may name something else entirely.
    remote=$(meta_field "$meta" remote_host)
    [ -z "$remote" ] || continue
    home=$(meta_field "$meta" home)
    [ -n "$home" ] || continue
    verdict=$(cmd_probe "$home")
    case "$verdict" in
      'stalled '*)
        verdict=${verdict#stalled }
        age=${verdict%% *}
        seq=${verdict##* }
        key="secondmate-wake-stall:$id:$seq"
        queue_key_exists "$key" && continue
        payload="check: secondmate-wake-stall $id: its durable wake queue has gone ${age}s unconsumed (oldest sequence $seq); a live agent process does not prove a live wake loop"
        if fm_wake_append check "$key" "$payload"; then
          printf 'actionable: %s\n' "$payload"
        else
          status=1
        fi
        ;;
      esac
  done
  if [ "$status" -eq 0 ]; then
    write_scan_marker || status=1
  fi
  return "$status"
}

case "${1:-}" in
  scan) shift; cmd_scan "$@" ;;
  probe) shift; [ "$#" -eq 1 ] || usage; cmd_probe "$1" ;;
  -h|--help) header ;;
  *) usage ;;
esac
