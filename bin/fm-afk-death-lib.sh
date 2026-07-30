#!/usr/bin/env bash
# Shared durable records for an away-mode daemon's intentional and unexpected
# exit lifecycle.
#
# The stop intent is exact to one daemon process: pid plus fm_pid_identity.
# A matching intent wins an exit race, because it was atomically published
# before the lifecycle owner asked that exact daemon to stop.
# An unexpected-exit record durably captures signal, timestamp, pid, and
# identity before the existing wedge-alarm channel is invoked.

FM_AFK_STOP_INTENT_NAME=".supervise-daemon.stop-intent"
FM_AFK_UNEXPECTED_EXIT_NAME=".supervise-daemon.unexpected-exit"
FM_AFK_START_PENDING_NAME=".supervise-daemon.start-pending"
FM_AFK_STOP_INTENT_PID=
FM_AFK_STOP_INTENT_IDENTITY=
FM_AFK_STOP_INTENT_PHASE=
FM_AFK_STOP_INTENT_PUBLISHER_PID=
FM_AFK_STOP_INTENT_PUBLISHER_IDENTITY=
FM_AFK_STOP_INTENT_RECORDED_AT=
FM_AFK_UNEXPECTED_EXIT_PID=
FM_AFK_UNEXPECTED_EXIT_IDENTITY=
FM_AFK_START_PENDING_RECORDED_AT=
FM_AFK_START_PENDING_EXPIRES_AT=

fm_afk_stop_intent_path() { printf '%s/%s\n' "$1" "$FM_AFK_STOP_INTENT_NAME"; }

fm_afk_unexpected_exit_path() { printf '%s/%s\n' "$1" "$FM_AFK_UNEXPECTED_EXIT_NAME"; }

fm_afk_start_pending_path() { printf '%s/%s\n' "$1" "$FM_AFK_START_PENDING_NAME"; }

fm_afk_death_valid_identity() {
  case "$1" in
    ''|*$'\n'*|*$'\r'*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_afk_stop_intent_write() {  # <state> <phase> <pid> <pid-identity> <publisher-pid> <publisher-identity> <recorded-at>
  local state=$1 phase=$2 pid=$3 identity=$4 publisher_pid=$5 publisher_identity=$6 recorded_at=$7 pending
  case "$phase" in published|consumed|abandoned) ;; *) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_afk_death_valid_identity "$identity" || return 1
  case "$publisher_pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_afk_death_valid_identity "$publisher_identity" || return 1
  mkdir -p "$state" || return 1
  pending=$(mktemp "$state/${FM_AFK_STOP_INTENT_NAME}.pending.XXXXXX") || return 1
  {
    printf 'phase=%s\n' "$phase"
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$identity"
    printf 'publisher_pid=%s\n' "$publisher_pid"
    printf 'publisher_identity=%s\n' "$publisher_identity"
    printf 'recorded_at=%s\n' "$recorded_at"
    printf 'phase_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$(fm_afk_stop_intent_path "$state")" || { rm -f "$pending"; return 1; }
}

fm_afk_stop_intent_publish() {  # <state> <pid> <pid-identity> <publisher-pid> <publisher-identity>
  local state=$1 lock result=0
  lock="$state/${FM_AFK_STOP_INTENT_NAME}.transition.lock"
  fm_lock_acquire_wait "$lock" || return 1
  fm_afk_stop_intent_write "$state" published "$2" "$3" "$4" "$5" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" || result=1
  fm_lock_release "$lock" 2>/dev/null || result=1
  return "$result"
}

fm_afk_stop_intent_read() {  # <state>
  local state=$1 path line1 line2 line3 line4 line5 line6 line7 lines
  FM_AFK_STOP_INTENT_PID=
  FM_AFK_STOP_INTENT_IDENTITY=
  FM_AFK_STOP_INTENT_PHASE=
  FM_AFK_STOP_INTENT_PUBLISHER_PID=
  FM_AFK_STOP_INTENT_PUBLISHER_IDENTITY=
  FM_AFK_STOP_INTENT_RECORDED_AT=
  path=$(fm_afk_stop_intent_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  lines=$(awk 'END { print NR }' "$path" 2>/dev/null) || return 1
  [ "$lines" = 7 ] || return 1
  line1=$(sed -n '1p' "$path") || return 1
  line2=$(sed -n '2p' "$path") || return 1
  line3=$(sed -n '3p' "$path") || return 1
  line4=$(sed -n '4p' "$path") || return 1
  line5=$(sed -n '5p' "$path") || return 1
  line6=$(sed -n '6p' "$path") || return 1
  line7=$(sed -n '7p' "$path") || return 1
  case "$line1" in phase=published|phase=consumed|phase=abandoned) FM_AFK_STOP_INTENT_PHASE=${line1#phase=} ;; *) return 1 ;; esac
  case "$line2" in pid=*) FM_AFK_STOP_INTENT_PID=${line2#pid=} ;; *) return 1 ;; esac
  case "$line3" in pid_identity=*) FM_AFK_STOP_INTENT_IDENTITY=${line3#pid_identity=} ;; *) return 1 ;; esac
  case "$line4" in publisher_pid=*) FM_AFK_STOP_INTENT_PUBLISHER_PID=${line4#publisher_pid=} ;; *) return 1 ;; esac
  case "$line5" in publisher_identity=*) FM_AFK_STOP_INTENT_PUBLISHER_IDENTITY=${line5#publisher_identity=} ;; *) return 1 ;; esac
  case "$line6" in recorded_at=????-??-??T??:??:??[+-]????) FM_AFK_STOP_INTENT_RECORDED_AT=${line6#recorded_at=} ;; *) return 1 ;; esac
  case "$line7" in phase_at=????-??-??T??:??:??[+-]????) ;; *) return 1 ;; esac
  case "$FM_AFK_STOP_INTENT_PID" in ''|*[!0-9]*) return 1 ;; esac
  fm_afk_death_valid_identity "$FM_AFK_STOP_INTENT_IDENTITY" || return 1
  case "$FM_AFK_STOP_INTENT_PUBLISHER_PID" in ''|*[!0-9]*) return 1 ;; esac
  fm_afk_death_valid_identity "$FM_AFK_STOP_INTENT_PUBLISHER_IDENTITY"
}

fm_afk_stop_intent_matches() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3
  fm_afk_stop_intent_read "$state" || return 1
  [ "$FM_AFK_STOP_INTENT_PID" = "$pid" ] \
    && [ "$FM_AFK_STOP_INTENT_IDENTITY" = "$identity" ]
}

fm_afk_stop_intent_publisher_alive() {
  local current_identity
  fm_pid_alive "$FM_AFK_STOP_INTENT_PUBLISHER_PID" || return 1
  current_identity=$(fm_pid_identity "$FM_AFK_STOP_INTENT_PUBLISHER_PID" 2>/dev/null) || return 1
  [ "$current_identity" = "$FM_AFK_STOP_INTENT_PUBLISHER_IDENTITY" ]
}

fm_afk_stop_intent_transition() {  # <state> <pid> <pid-identity> <from-phase> <to-phase>
  local state=$1 pid=$2 identity=$3 from_phase=$4 to_phase=$5 lock result=1
  lock="$state/${FM_AFK_STOP_INTENT_NAME}.transition.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_afk_stop_intent_read "$state" \
    && [ "$FM_AFK_STOP_INTENT_PID" = "$pid" ] \
    && [ "$FM_AFK_STOP_INTENT_IDENTITY" = "$identity" ]; then
    if [ "$FM_AFK_STOP_INTENT_PHASE" = "$to_phase" ]; then
      result=0
    elif [ "$FM_AFK_STOP_INTENT_PHASE" = "$from_phase" ] \
      && fm_afk_stop_intent_write "$state" "$to_phase" "$pid" "$identity" \
        "$FM_AFK_STOP_INTENT_PUBLISHER_PID" "$FM_AFK_STOP_INTENT_PUBLISHER_IDENTITY" \
        "$FM_AFK_STOP_INTENT_RECORDED_AT"; then
      result=0
    fi
  fi
  fm_lock_release "$lock" 2>/dev/null || result=1
  return "$result"
}

fm_afk_stop_intent_consume() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3 lock result=1 target_phase=abandoned
  lock="$state/${FM_AFK_STOP_INTENT_NAME}.transition.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_afk_stop_intent_read "$state" \
    && [ "$FM_AFK_STOP_INTENT_PID" = "$pid" ] \
    && [ "$FM_AFK_STOP_INTENT_IDENTITY" = "$identity" ]; then
    if [ "$FM_AFK_STOP_INTENT_PHASE" = consumed ]; then
      result=0
    elif [ "$FM_AFK_STOP_INTENT_PHASE" = published ]; then
      if fm_afk_stop_intent_publisher_alive; then
        target_phase=consumed
      fi
      if fm_afk_stop_intent_write "$state" "$target_phase" "$pid" "$identity" \
        "$FM_AFK_STOP_INTENT_PUBLISHER_PID" "$FM_AFK_STOP_INTENT_PUBLISHER_IDENTITY" \
        "$FM_AFK_STOP_INTENT_RECORDED_AT" \
        && [ "$target_phase" = consumed ]; then
        result=0
      fi
    fi
  fi
  fm_lock_release "$lock" 2>/dev/null || result=1
  return "$result"
}

fm_afk_stop_intent_abandon() {  # <state> <pid> <pid-identity>
  fm_afk_stop_intent_transition "$1" "$2" "$3" published abandoned
}

fm_afk_stop_intent_retire() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3 path lock result=1
  lock="$state/${FM_AFK_STOP_INTENT_NAME}.transition.lock"
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_afk_stop_intent_path "$state")
  if fm_afk_stop_intent_matches "$state" "$pid" "$identity" && rm -f "$path"; then
    result=0
  fi
  fm_lock_release "$lock" 2>/dev/null || result=1
  return "$result"
}

fm_afk_start_pending_publish() {  # <state>
  local state=$1 seconds now pending
  seconds=${FM_AFK_START_PENDING_SECS:-60}
  case "$seconds" in ''|*[!0-9]*|0) return 1 ;; esac
  now=$(date '+%s') || return 1
  mkdir -p "$state" || return 1
  pending=$(mktemp "$state/${FM_AFK_START_PENDING_NAME}.pending.XXXXXX") || return 1
  {
    printf 'recorded_at_epoch=%s\n' "$now"
    printf 'expires_at_epoch=%s\n' "$((now + seconds))"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$(fm_afk_start_pending_path "$state")" || { rm -f "$pending"; return 1; }
}

fm_afk_start_pending_read() {  # <state>
  local state=$1 path line1 line2 lines
  FM_AFK_START_PENDING_RECORDED_AT=
  FM_AFK_START_PENDING_EXPIRES_AT=
  path=$(fm_afk_start_pending_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  lines=$(awk 'END { print NR }' "$path" 2>/dev/null) || return 1
  [ "$lines" = 2 ] || return 1
  line1=$(sed -n '1p' "$path") || return 1
  line2=$(sed -n '2p' "$path") || return 1
  case "$line1" in recorded_at_epoch=*) FM_AFK_START_PENDING_RECORDED_AT=${line1#recorded_at_epoch=} ;; *) return 1 ;; esac
  case "$line2" in expires_at_epoch=*) FM_AFK_START_PENDING_EXPIRES_AT=${line2#expires_at_epoch=} ;; *) return 1 ;; esac
  case "$FM_AFK_START_PENDING_RECORDED_AT" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_AFK_START_PENDING_EXPIRES_AT" in ''|*[!0-9]*) return 1 ;; esac
  [ "$FM_AFK_START_PENDING_EXPIRES_AT" -ge "$FM_AFK_START_PENDING_RECORDED_AT" ]
}

fm_afk_start_pending_active() {  # <state>
  local now
  fm_afk_start_pending_read "$1" || return 1
  now=$(date '+%s') || return 1
  [ "$now" -le "$FM_AFK_START_PENDING_EXPIRES_AT" ]
}

fm_afk_start_pending_clear() {  # <state>
  rm -f "$(fm_afk_start_pending_path "$1")"
}

fm_afk_unexpected_exit_read() {  # <state>
  local state=$1 path line1 line2 line3 line4 lines
  FM_AFK_UNEXPECTED_EXIT_PID=
  FM_AFK_UNEXPECTED_EXIT_IDENTITY=
  path=$(fm_afk_unexpected_exit_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  lines=$(awk 'END { print NR }' "$path" 2>/dev/null) || return 1
  [ "$lines" = 4 ] || return 1
  line1=$(sed -n '1p' "$path") || return 1
  line2=$(sed -n '2p' "$path") || return 1
  line3=$(sed -n '3p' "$path") || return 1
  line4=$(sed -n '4p' "$path") || return 1
  case "$line1" in signal=?*) ;; *) return 1 ;; esac
  case "$line2" in recorded_at=????-??-??T??:??:??[+-]????) ;; *) return 1 ;; esac
  case "$line3" in pid=*) FM_AFK_UNEXPECTED_EXIT_PID=${line3#pid=} ;; *) return 1 ;; esac
  case "$line4" in pid_identity=*) FM_AFK_UNEXPECTED_EXIT_IDENTITY=${line4#pid_identity=} ;; *) return 1 ;; esac
  case "$FM_AFK_UNEXPECTED_EXIT_PID" in MISSING) ;; ''|*[!0-9]*) return 1 ;; esac
  fm_afk_death_valid_identity "$FM_AFK_UNEXPECTED_EXIT_IDENTITY"
}

fm_afk_unexpected_exit_matches() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3
  fm_afk_unexpected_exit_read "$state" || return 1
  [ "$FM_AFK_UNEXPECTED_EXIT_PID" = "$pid" ] \
    && [ "$FM_AFK_UNEXPECTED_EXIT_IDENTITY" = "$identity" ]
}

fm_afk_unexpected_exit_record() {  # <state> <signal> <pid> <pid-identity>
  local state=$1 signal=$2 pid=$3 identity=$4 pending path
  case "$signal" in ''|*$'\n'*|*$'\r'*) return 1 ;; esac
  case "$pid" in MISSING) ;; ''|*[!0-9]*) return 1 ;; esac
  fm_afk_death_valid_identity "$identity" || return 1
  mkdir -p "$state" || return 1
  pending=$(mktemp "$state/${FM_AFK_UNEXPECTED_EXIT_NAME}.pending.XXXXXX") || return 1
  {
    printf 'signal=%s\n' "$signal"
    printf 'recorded_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$identity"
  } > "$pending" || { rm -f "$pending"; return 1; }
  path=$(fm_afk_unexpected_exit_path "$state")
  if ln "$pending" "$path" 2>/dev/null; then
    rm -f "$pending"
    return 0
  fi
  rm -f "$pending"
  fm_afk_unexpected_exit_read "$state" && return 2
  return 1
}
