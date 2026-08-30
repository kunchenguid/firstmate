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
#    the file passes FM_WAKE_DELIVERY_MAX_BYTES (default 131072) under the
#    sibling .lock mkdir lock, best-effort. bin/fm-bootstrap.sh surfaces the
#    record as one actionable WAKE_DELIVERY diagnostic at the next session
#    start and then archives it to .wake-delivery-failures.surfaced.
# 2. The active-notification cooldown marker $STATE/.wake-delivery-alarm: the
#    epoch second of the last fired active alert. At most one active alert per
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

usage() {
  printf 'usage: %s --summary <one-line summary>\n' "${0##*/}" >&2
}

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

# The append is the load-bearing half: it must land even when trimming or the
# active alert cannot run, so it happens first and outside the lock.
printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$summary" >> "$record" 2>/dev/null || exit 0

size=$(wc -c < "$record" 2>/dev/null | tr -d '[:space:]') || exit 0
case "$size" in ''|*[!0-9]*) exit 0 ;; esac
if [ "$size" -gt "$max_bytes" ]; then
  # Contention skips the trim rather than blocking a failure path; the next
  # failure retries it. The lock is a directory so a crashed holder self-heals
  # through rmdir below and stale locks age out of the way.
  if mkdir "$lock" 2>/dev/null; then
    if tail -n "$keep_lines" "$record" > "$record.tmp" 2>/dev/null && [ -s "$record.tmp" ]; then
      mv "$record.tmp" "$record" 2>/dev/null || true
    fi
    rm -f "$record.tmp" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
  fi
fi

cooldown=${FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS:-600}
case "$cooldown" in ''|*[!0-9]*) cooldown=600 ;; esac

marker="$STATE/.wake-delivery-alarm"
now=$(date +%s)
last=0
[ -r "$marker" ] && read -r last < "$marker" 2>/dev/null || true
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ "$cooldown" -gt 0 ] && [ $((now - last)) -lt "$cooldown" ]; then
  exit 0
fi
printf '%s\n' "$now" > "$marker" 2>/dev/null || true

wedge_alarm_notify \
  "firstmate: OpenCode wake delivery FAILED - $summary (see $record)" \
  "$record" \
  "firstmate: OpenCode wake delivery FAILED"
exit 0
