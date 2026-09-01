#!/usr/bin/env bash
# Loud-failure path for OpenCode primary wake delivery.
# A failed wake-injection promptAsync used to be completely silent: callers
# swallowed the rejection, and a stale OpenCode TUI build (whose client API
# drifted from the plugins) could swallow every finish-notification in the
# fleet while the durable wake queue stayed correct. The OpenCode plugins in
# .opencode/plugins/ route every wake-delivery prompt through
# lib/fm-wake-delivery.js, which retries a bounded number of times and then
# invokes this script. This script owns exactly three things:
#
# 1. The durable failure record $STATE/.wake-delivery-failures: one appended
#    line per declared failure, `<iso8601-stamp>\t<single-line summary>`,
#    trimmed to the last FM_WAKE_DELIVERY_KEEP_LINES lines (default 200) once
#    the file passes FM_WAKE_DELIVERY_MAX_BYTES (default 131072). The append
#    and any resulting trim share the sibling .lock mkdir lock (bin/
#    fm-wake-delivery-lock-lib.sh; bounded, not indefinite, and self-healing -
#    an abandoned lock is reaped once its stamped pid is dead, or once no pid
#    was ever recorded, and it has aged past the stale threshold either way)
#    so a concurrent invocation's append can never be excluded from a trim's
#    replacement snapshot; a caller that cannot get the lock within the bound
#    still appends unlocked rather than drop the failure, and the trim
#    re-checks the file's size immediately before swapping in its snapshot so
#    that unlocked append can never be discarded by the swap. bin/
#    fm-bootstrap.sh surfaces the record as one actionable WAKE_DELIVERY
#    diagnostic at the next session start and archives it to
#    .wake-delivery-failures.surfaced under the SAME lock with the same
#    size-recheck, so a concurrent append can never be silently swallowed by
#    the archive either.
# 2. The active-notification cooldown marker $STATE/.wake-delivery-alarm: the
#    epoch second of the last fired active alert, gated by its own bounded,
#    self-healing mkdir lock so concurrent invocations racing an expired
#    cooldown cannot all decide to fire. At most one active alert per
#    FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS (default 600) fires so a persistently
#    broken build records every failure without spamming the captain; the
#    durable record above is always written. 0 disables the cooldown.
# 3. Channel reuse: active alerts fire through the wedge-alarm channel
#    machinery in fm-wedge-alarm-lib.sh (config/wedge-alarm directives,
#    FM_WEDGE_ALARM_CHANNEL override, and the FM_WEDGE_ALARM_EXEC test seam),
#    not a new notification channel.
#
# Usage: fm-wake-delivery-alarm.sh --summary <one-line summary>
# Every path is best-effort and exits 0: an alarm failure must never disturb
# the caller's own failure handling.
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, plus the
# wedge-alarm lib's FM_WEDGE_ALARM_* variables.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$SCRIPT_DIR/fm-wedge-alarm-lib.sh"
# shellcheck source=bin/fm-wake-delivery-lock-lib.sh
. "$SCRIPT_DIR/fm-wake-delivery-lock-lib.sh"

usage() {
  printf 'usage: %s --summary <one-line summary>\n' "${0##*/}" >&2
}

LOCK_STALE_SECS=30

summary=""
while [ $# -gt 0 ]; do
  case "$1" in
    --summary)
      [ $# -ge 2 ] || { usage; exit 0; }
      summary=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 0
      ;;
  esac
done

# One durable line, no matter what the caller passed.
summary=$(printf '%s' "$summary" | tr '\t\r\n' '   ' | cut -c1-300)
[ -n "$summary" ] || exit 0

mkdir -p "$STATE" 2>/dev/null || true
[ -d "$STATE" ] || exit 0
record="$STATE/.wake-delivery-failures"
lock="$STATE/.wake-delivery-failures.lock"
keep_lines=${FM_WAKE_DELIVERY_KEEP_LINES:-200}
max_bytes=${FM_WAKE_DELIVERY_MAX_BYTES:-131072}
case "$keep_lines" in ''|*[!0-9]*|0) keep_lines=200 ;; esac
case "$max_bytes" in ''|*[!0-9]*|0) max_bytes=131072 ;; esac

# The append is the load-bearing half: it must land no matter what, so a
# caller that cannot get the lock within the bound still appends unlocked -
# and a stuck holder makes that unlocked fallback race any trim/archive that
# IS holding the lock at that moment. A trim's `tail | mv` snapshot-and-swap
# reads the file, then replaces it outright; if the fallback append lands
# between that read and the swap, the swap discards it for good even though
# the append itself landed. So the trim re-checks the file's size immediately
# before the swap and skips the swap if it moved - proof some other write
# landed after the snapshot was taken - leaving the (still slightly oversized)
# record untouched for the next trim to retry rather than lose the line.
line=$(printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$summary")
if fm_wake_delivery_acquire_lock "$lock" 40 0.05 "$LOCK_STALE_SECS"; then
  printf '%s\n' "$line" >> "$record" 2>/dev/null || { fm_wake_delivery_release_lock "$lock"; exit 0; }
  size=$(wc -c < "$record" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) fm_wake_delivery_release_lock "$lock"; exit 0 ;;
  esac
  if [ "$size" -gt "$max_bytes" ]; then
    if tail -n "$keep_lines" "$record" > "$record.tmp" 2>/dev/null && [ -s "$record.tmp" ]; then
      size_now=$(wc -c < "$record" 2>/dev/null | tr -d '[:space:]')
      if [ "$size_now" = "$size" ]; then
        mv "$record.tmp" "$record" 2>/dev/null || true
      fi
    fi
    rm -f "$record.tmp" 2>/dev/null || true
  fi
  fm_wake_delivery_release_lock "$lock"
else
  printf '%s\n' "$line" >> "$record" 2>/dev/null || exit 0
fi

cooldown=${FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS:-600}
case "$cooldown" in ''|*[!0-9]*) cooldown=600 ;; esac

marker="$STATE/.wake-delivery-alarm"
marker_lock="$STATE/.wake-delivery-alarm.lock"
now=$(date +%s)

# The cooldown check (is the window still active?) and set (claim it) must be
# one atomic step: reading the marker and then writing it as two separate
# operations lets every concurrent caller past an expired cooldown see it as
# expired before any of them records the claim, so all of them fire the active
# alert. Only the lock holder evaluates and claims the window; a caller that
# cannot acquire it within the bound treats the window as already claimed and
# stays quiet rather than risk a duplicate captain notification.
should_notify=0
if fm_wake_delivery_acquire_lock "$marker_lock" 40 0.05 "$LOCK_STALE_SECS"; then
  last=0
  [ -r "$marker" ] && read -r last < "$marker" 2>/dev/null || true
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$cooldown" -eq 0 ] || [ $((now - last)) -ge "$cooldown" ]; then
    printf '%s\n' "$now" > "$marker" 2>/dev/null || true
    should_notify=1
  fi
  fm_wake_delivery_release_lock "$marker_lock"
fi
[ "$should_notify" -eq 1 ] || exit 0

wedge_alarm_notify \
  "firstmate: OpenCode wake delivery FAILED - $summary (see $record)" \
  "$record" \
  "firstmate: OpenCode wake delivery FAILED"
exit 0
