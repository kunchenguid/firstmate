#!/usr/bin/env bash
# fm-afk-alarm.sh - the away posture's supervisor-failure channel: the loud
# local marker plus the hold record that replace waking main while the
# away-posture record exists (docs/pi-supervision-branch.md "Postures").
#
# WHY. While the captain is attended, a watcher-failure alarm and a wake the
# supervision branch cannot take both reach main, which repairs or handles
# them. While the away-posture record (state/.afk-contract, owner
# bin/fm-afk-contract.sh) exists, main is parked and receives no wakes at all,
# so those failures need a channel that is silent to the sleeping captain but
# impossible to miss at return: nothing is lost (the durable wake queue still
# holds every unhandled row for the return drain), and nothing is hidden
# (the return brief leads with supervisor health, which reads this marker).
#
# MARKER. state/.afk-supervisor-alarm, append-only while the away window
# lasts: one line per alarm, "<epoch>\t<summary>", the summary reduced to one
# line with tabs and control characters removed. bin/fm-afk-return.sh reads
# it into the health section of the return brief and removes it once the
# return catch-up clears, exactly as it does the daemon's wedge marker.
#
# HOLD RECORD. Each alarm also holds the fixed backlog task
# fm-afk-supervisor-alarm for the captain through bin/fm-captain-hold.sh
# (created on first use), so the failure is also a captain call the ordinary
# OPEN DECISIONS and Bearings surfaces list. The hold is idempotent: a repeat
# preserves the existing hold. It is best-effort: when the backlog backend
# cannot record it, the marker still stands and this script exits 4 so the
# caller can log the gap; the marker is the guarantee, the hold the courtesy.
#
# The reach ladder above the marker (a local notice, a phone tier) is a later
# phase; this script is the seam it will hang from.
#
# Usage:
#   fm-afk-alarm.sh raise <summary...>
#     Append one alarm and hold the record. Exit 0 when both landed, 4 when
#     the marker landed but the hold record could not be written, 3 when no
#     away-posture record exists (an attended failure reaches main directly
#     and never uses this channel), 2 on a usage error, 1 when the marker
#     itself could not be written.
#   fm-afk-alarm.sh present
#     Exit 0 when the marker holds at least one alarm, 1 otherwise.
#   fm-afk-alarm.sh list
#     Print every recorded alarm line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FM_AFK_ALARM_MARKER="$STATE/.afk-supervisor-alarm"
FM_AFK_ALARM_TASK=fm-afk-supervisor-alarm
FM_AFK_ALARM_TITLE='Supervisor failure during the away window'
FM_AFK_ALARM_REASON='the supervisor raised an alarm while you were away - state/.afk-supervisor-alarm has every line'

fm_afk_alarm_log() { printf 'fm-afk-alarm: %s\n' "$*" >&2; }

fm_afk_alarm_present() {
  [ -s "$FM_AFK_ALARM_MARKER" ]
}

fm_afk_alarm_raise() {  # <summary...>
  local summary
  [ "$#" -gt 0 ] || { fm_afk_alarm_log 'raise needs a summary'; return 2; }
  summary=$(printf '%s ' "$@" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$summary" ] || summary='(no detail)'
  if ! FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1; then
    fm_afk_alarm_log 'no confirmed away-posture record exists; an attended failure reaches main directly'
    return 3
  fi
  if ! printf '%s\t%s\n' "$(date +%s)" "$summary" >> "$FM_AFK_ALARM_MARKER"; then
    fm_afk_alarm_log "could not write the alarm marker at $FM_AFK_ALARM_MARKER"
    return 1
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-captain-hold.sh" hold "$FM_AFK_ALARM_TASK" \
      --title "$FM_AFK_ALARM_TITLE" --reason "$FM_AFK_ALARM_REASON" >/dev/null 2>&1; then
    fm_afk_alarm_log "alarm recorded at $FM_AFK_ALARM_MARKER, but the hold record $FM_AFK_ALARM_TASK could not be written"
    return 4
  fi
  return 0
}

fm_afk_alarm_main() {
  local cmd=${1:-}
  shift 2>/dev/null || true
  case "$cmd" in
    raise) fm_afk_alarm_raise "$@" ;;
    present) [ "$#" -eq 0 ] || return 2; fm_afk_alarm_present ;;
    list)
      [ "$#" -eq 0 ] || return 2
      [ -f "$FM_AFK_ALARM_MARKER" ] && cat "$FM_AFK_ALARM_MARKER"
      return 0
      ;;
    *)
      echo 'usage: fm-afk-alarm.sh raise <summary...> | present | list' >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_alarm_main "$@"
fi
