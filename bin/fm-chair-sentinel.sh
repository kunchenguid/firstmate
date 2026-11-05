#!/usr/bin/env bash
# fm-chair-sentinel.sh - the deterministic decider for the firstmate chair.
#
# Usage:
#   fm-chair-sentinel.sh            one decision tick (the LaunchAgent default)
#   fm-chair-sentinel.sh arm        install and load the LaunchAgent; retires the
#                                   legacy model-driven ai.muso.lane-tick-chair-flipper
#                                   LaunchAgent first (bootout + remove) so only one
#                                   actuator ever ticks the chair
#   fm-chair-sentinel.sh disarm     unload and remove the LaunchAgent
#   fm-chair-sentinel.sh status     report the LaunchAgent and last tick
#
# One tick runs the sensor (bin/fm-chair-runway.sh) and the chair status
# (bin/fm-chair-status.sh), applies the table, acts through
# bin/fm-chair-flip.sh, and appends one line to data/chair-sentinel/log.jsonl.
# It calls no model anywhere.
#
#   Fable green   + chair pi-fable on a green source -> nothing
#   Fable green   + chair pi-fable whose bound source (8317 or 8080, from the
#                   status line's source=) is RED  -> re-seat: flip to-pi-fable
#                                                     on the green source,
#                                                     handoff first, under the
#                                                     actuator's hysteresis
#   Fable green   + chair pi-fable whose bound source is UNKNOWN (no record
#                   and no session file names it)   -> nothing: an unknown source
#                                                     never causes a re-seat on
#                                                     its own, it only means the
#                                                     source-red row cannot fire
#   Fable green   + any other chair                -> flip to-pi-fable
#   Fable red     + Grok above floor + chair grok  -> nothing
#   Fable red     + Grok above floor + any other   -> flip to-grok
#   Fable unknown + Grok above floor + chair grok  -> nothing (no alarm)
#   Fable unknown + Grok above floor + chair pi-fable
#                                                  -> hold for up to 3 consecutive
#                                                     unknown ticks (15 min), then
#                                                     treat Fable as red: flip
#                                                     to-grok
#   Fable unknown + Grok above floor + none|other  -> flip to-grok (a live chair
#                                                     beats no chair)
#   otherwise (no green tank)                      -> no flip; write
#                                                     state/.chair-alarm and print
#                                                     the captain-facing line naming
#                                                     the 8080 accounts a human must
#                                                     log in
#
# Fable is primary. A Grok chair is a fallback for a Fable blackout and is
# replaced as soon as Fable is green again, after the handoff file is written;
# the actuator's 30-minute hysteresis is what stops a flapping 8317 from
# bouncing the chair. Fable `unknown` (probe timeout or 5xx) is never an alarm
# on its own and never causes a flip toward Fable. "Any other chair" includes
# `none` and a foreign harness such as `claude` or `codex`: the actuator ends
# it gracefully with its own exit command before any SIGTERM, and it is never
# an alarm.
#
# The consecutive-unknown count lives in state/.chair-fable-unknown-ticks and
# resets on any tick where Fable is measured.
#
# Once a tick has seen a chair, its source is cached in state/.chair-source
# keyed by the lock pid (the same record the actuator writes for a chair it
# launched): a named source (8317, 8080 or grok) is never re-derived while that
# pid holds the lock; a cached `unknown` is re-derived by the status sensor
# every tick and replaced as soon as a session names the tank.
#
# FM_CHAIR_SENTINEL_DRY_RUN=1 passes the dry run through to the actuator.
#
# Test seams:
#   FM_CHAIR_SENTINEL_SENSOR_CMD   override the sensor
#   FM_CHAIR_SENTINEL_STATUS_CMD   override the chair status
#   FM_CHAIR_SENTINEL_FLIP_CMD     override the actuator
#   FM_CHAIR_SENTINEL_HOME         home directory
#   FM_CHAIR_SENTINEL_LA_DIR       LaunchAgents directory (default ~/Library/LaunchAgents)
#   FM_CHAIR_SENTINEL_LAUNCHCTL    launchctl (default: launchctl)
#   FM_CHAIR_SENTINEL_NOW          epoch seconds to use as now
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
HOME_DIR=${FM_CHAIR_SENTINEL_HOME:-$FM_HOME}
ABS_HOME=$(cd -- "$HOME_DIR" 2>/dev/null && pwd -P) || ABS_HOME=$HOME_DIR
STATE_DIR=$ABS_HOME/state
DATA_DIR=$ABS_HOME/data
LOG_DIR=$DATA_DIR/chair-sentinel
LOG_FILE=$LOG_DIR/log.jsonl
ALARM_FILE=$STATE_DIR/.chair-alarm
UNKNOWN_TICKS_FILE=$STATE_DIR/.chair-fable-unknown-ticks
SOURCE_FILE=$STATE_DIR/.chair-source
UNKNOWN_HOLD_TICKS=3
LABEL=ai.muso.chair-sentinel
LEGACY_LABEL=ai.muso.lane-tick-chair-flipper
LA_DIR=${FM_CHAIR_SENTINEL_LA_DIR:-${HOME:-}/Library/LaunchAgents}
PLIST=$LA_DIR/$LABEL.plist
LEGACY_PLIST=$LA_DIR/$LEGACY_LABEL.plist
LAUNCHCTL=${FM_CHAIR_SENTINEL_LAUNCHCTL:-launchctl}
# launchd starts jobs with /usr/bin:/bin:/usr/sbin:/sbin only; orca, pi,
# quota-axi and grok live in the user's tool dirs.
LAUNCHD_PATH=${HOME:-}/.local/bin:${HOME:-}/.npm-global/bin:${HOME:-}/.grok/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

extract_field() {  # <line> <key>
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\([^ ]*\).*/\1/p" | head -1
}

sensor_line() {
  if [ -n "${FM_CHAIR_SENTINEL_SENSOR_CMD:-}" ]; then
    "$FM_CHAIR_SENTINEL_SENSOR_CMD" 2>/dev/null
  else
    FM_HOME="$ABS_HOME" "$SCRIPT_DIR/fm-chair-runway.sh" 2>/dev/null
  fi
}

chair_line() {
  if [ -n "${FM_CHAIR_SENTINEL_STATUS_CMD:-}" ]; then
    "$FM_CHAIR_SENTINEL_STATUS_CMD" 2>/dev/null
  else
    FM_HOME="$ABS_HOME" "$SCRIPT_DIR/fm-chair-status.sh" 2>/dev/null
  fi
}

flip_to() {  # <to-pi-fable|to-grok>
  if [ -n "${FM_CHAIR_SENTINEL_FLIP_CMD:-}" ]; then
    FM_CHAIR_FLIP_HOME="$ABS_HOME" FM_CHAIR_FLIP_DRY_RUN="${FM_CHAIR_SENTINEL_DRY_RUN:-0}" "$FM_CHAIR_SENTINEL_FLIP_CMD" "$1"
  else
    FM_CHAIR_FLIP_HOME="$ABS_HOME" FM_CHAIR_FLIP_DRY_RUN="${FM_CHAIR_SENTINEL_DRY_RUN:-0}" "$SCRIPT_DIR/fm-chair-flip.sh" "$1"
  fi
}

run_tick() {
  local sensor status fable grok chair terminal decision action alarm_names flip_out flip_code source unknown_ticks
  local pool8317 ccflare chair_source bound_state chair_pid cached cached_pid cached_source
  sensor=$(sensor_line)
  status=$(chair_line)
  fable=$(extract_field "$sensor" fable)
  pool8317=$(extract_field "$sensor" pool8317)
  ccflare=$(extract_field "$sensor" ccflare)
  grok=$(extract_field "$sensor" grok)
  chair=$(extract_field "$status" chair)
  chair_source=$(extract_field "$status" source)
  chair_pid=$(extract_field "$status" pid)
  terminal=$(extract_field "$status" terminal)
  alarm_names=$(extract_field "$sensor" names)

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  unknown_ticks=0
  if [ "$fable" = unknown ]; then
    unknown_ticks=$(cat -- "$UNKNOWN_TICKS_FILE" 2>/dev/null) || unknown_ticks=0
    case "$unknown_ticks" in ''|*[!0-9]*) unknown_ticks=0 ;; esac
    unknown_ticks=$((unknown_ticks + 1))
    printf '%s\n' "$unknown_ticks" > "$UNKNOWN_TICKS_FILE" 2>/dev/null || true
  else
    rm -f "$UNKNOWN_TICKS_FILE" 2>/dev/null || true
  fi

  decision=none
  action=none
  case "$chair_source" in
    8317) bound_state=$pool8317 ;;
    8080) bound_state=$ccflare ;;
    *) bound_state=none ;;
  esac
  case "$chair_pid:$chair_source" in
    none:*|:*|*:none|*:) ;;
    *)
      cached=$(head -n 1 -- "$SOURCE_FILE" 2>/dev/null) || cached=''
      cached_pid=$(printf '%s\n' "$cached" | sed -n 's/.*pid=\([^ ]*\).*/\1/p')
      cached_source=$(printf '%s\n' "$cached" | sed -n 's/.*source=\([^ ]*\).*/\1/p')
      if [ "$cached_pid" != "$chair_pid" ] || { [ "$cached_source" = unknown ] && [ "$chair_source" != unknown ]; }; then
        printf 'pid=%s source=%s launched_at=%s\n' "$chair_pid" "$chair_source" "${FM_CHAIR_SENTINEL_NOW:-$(date +%s)}" > "$SOURCE_FILE" 2>/dev/null || true
      fi
      ;;
  esac
  if [ "$fable" = green ]; then
    if [ "$chair" = pi-fable ] && [ "$bound_state" = red ]; then
      decision=chair_source_red_reseat
      action=to-pi-fable
    elif [ "$chair" = pi-fable ]; then
      decision=fable_green_chair_ok
    else
      decision=fable_green_chair_wrong
      action=to-pi-fable
    fi
  elif [ "$fable" = red ] && [ "$grok" = green ]; then
    if [ "$chair" = grok ]; then
      decision=grok_red_chair_ok
    else
      decision=grok_blackout_chair_wrong
      action=to-grok
    fi
  elif [ "$fable" = unknown ] && [ "$grok" = green ]; then
    if [ "$chair" = grok ]; then
      decision=grok_chair_ok_fable_unmeasured
    elif [ "$chair" = pi-fable ] && [ "$unknown_ticks" -lt "$UNKNOWN_HOLD_TICKS" ]; then
      decision=fable_unmeasured_hold
    elif [ "$chair" = pi-fable ]; then
      decision=fable_unmeasured_expired
      action=to-grok
    else
      decision=fable_unmeasured_no_chair
      action=to-grok
    fi
  else
    decision=no_tank
  fi

  if [ "$decision" = no_tank ]; then
    printf 'no tank: fable=%s grok=%s chair=%s\n' "$fable" "$grok" "$chair" > "$ALARM_FILE" 2>/dev/null || true
    printf 'Captain, firstmate has no tank: Fable=%s, SuperGrok=%s. better-ccflare accounts needing a human login: %s\n' \
      "$fable" "$grok" "${alarm_names:-unknown}"
  else
    rm -f "$ALARM_FILE" 2>/dev/null || true
  fi

  flip_code=null
  source=none
  if [ "$action" != none ]; then
    flip_out=$(flip_to "$action" 2>&1); flip_code=$?
    [ -z "$flip_out" ] || printf '%s\n' "$flip_out"
    source=$(extract_field "$flip_out" source)
    source=${source:-none}
  fi

  mkdir -p "$LOG_DIR" 2>/dev/null || true
  local now
  now=${FM_CHAIR_SENTINEL_NOW:-$(date +%s)}
  printf '{"at":%s,"fable":"%s","grok":"%s","chair":"%s","chair_source":"%s","terminal":"%s","decision":"%s","action":"%s","source":"%s","flip_exit":%s,"fable_unknown_ticks":%s}\n' \
    "$now" "$fable" "$grok" "$chair" "${chair_source:-none}" "$terminal" "$decision" "$action" "$source" "$flip_code" "$unknown_ticks" >> "$LOG_FILE" 2>/dev/null || true

  printf 'chair-sentinel: fable=%s grok=%s chair=%s chair_source=%s decision=%s action=%s source=%s flip_exit=%s fable_unknown_ticks=%s\n' \
    "$fable" "$grok" "$chair" "${chair_source:-none}" "$decision" "$action" "$source" "$flip_code" "$unknown_ticks"
}

write_plist() {
  mkdir -p "$LA_DIR" 2>/dev/null || { echo "chair-sentinel: cannot create $LA_DIR" >&2; return 1; }
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$SCRIPT_DIR/fm-chair-sentinel.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$ABS_HOME</string>
    <key>PATH</key><string>$LAUNCHD_PATH</string>
  </dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/agent.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/agent.err</string>
</dict></plist>
PLISTEOF
}

case "${1:-tick}" in
  tick|'') run_tick ;;
  arm)
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [ -f "$LEGACY_PLIST" ] || "$LAUNCHCTL" list 2>/dev/null | grep -q "$LEGACY_LABEL"; then
      "$LAUNCHCTL" bootout "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1 || true
      rm -f "$LEGACY_PLIST" 2>/dev/null || true
      echo "chair-sentinel: retired legacy tick $LEGACY_LABEL ($LEGACY_PLIST removed)"
    fi
    write_plist || exit 1
    "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    if [ "$(uname -s)" != Darwin ]; then
      echo "chair-sentinel: launchd install is macOS-only; on $(uname -s) use the systemd unit instead" >&2
      exit 0
    fi
    "$LAUNCHCTL" load "$PLIST" || { echo "chair-sentinel: launchctl load failed" >&2; exit 1; }
    echo "chair-sentinel: armed ($PLIST)"
    ;;
  disarm)
    "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST" 2>/dev/null || true
    echo "chair-sentinel: disarmed"
    ;;
  status)
    if [ -f "$PLIST" ]; then echo "plist: present ($PLIST)"; else echo "plist: absent"; fi
    if "$LAUNCHCTL" list 2>/dev/null | grep -q "$LABEL"; then echo "launchd: loaded"; else echo "launchd: not loaded"; fi
    if [ -f "$LOG_FILE" ]; then echo "last tick: $(tail -n 1 "$LOG_FILE")"; else echo "last tick: none"; fi
    if [ -f "$ALARM_FILE" ]; then echo "alarm: $(cat "$ALARM_FILE")"; else echo "alarm: none"; fi
    ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac