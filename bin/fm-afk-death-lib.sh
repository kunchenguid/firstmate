#!/usr/bin/env bash
# Shared durable records for an away-mode daemon's intentional and unexpected
# exit lifecycle.
#
# The stop intent is exact to one daemon process: pid plus fm_pid_identity.
# A matching intent wins an exit race, because it was atomically published
# before the lifecycle owner asked that exact daemon to stop.

FM_AFK_STOP_INTENT_NAME=".supervise-daemon.stop-intent"
FM_AFK_UNEXPECTED_EXIT_NAME=".supervise-daemon.unexpected-exit"

fm_afk_stop_intent_path() { printf '%s/%s\n' "$1" "$FM_AFK_STOP_INTENT_NAME"; }

fm_afk_unexpected_exit_path() { printf '%s/%s\n' "$1" "$FM_AFK_UNEXPECTED_EXIT_NAME"; }

fm_afk_death_valid_identity() {
  case "$1" in
    ''|*$'\n'*|*$'\r'*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_afk_stop_intent_publish() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3 pending
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_afk_death_valid_identity "$identity" || return 1
  mkdir -p "$state" || return 1
  pending=$(mktemp "$state/${FM_AFK_STOP_INTENT_NAME}.pending.XXXXXX") || return 1
  {
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$identity"
    printf 'recorded_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$(fm_afk_stop_intent_path "$state")" || { rm -f "$pending"; return 1; }
}

fm_afk_stop_intent_matches() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3 path line1 line2 line3 intent_pid intent_identity lines
  path=$(fm_afk_stop_intent_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  lines=$(awk 'END { print NR }' "$path" 2>/dev/null) || return 1
  [ "$lines" = 3 ] || return 1
  line1=$(sed -n '1p' "$path") || return 1
  line2=$(sed -n '2p' "$path") || return 1
  line3=$(sed -n '3p' "$path") || return 1
  case "$line1" in pid=*) intent_pid=${line1#pid=} ;; *) return 1 ;; esac
  case "$line2" in pid_identity=*) intent_identity=${line2#pid_identity=} ;; *) return 1 ;; esac
  case "$line3" in recorded_at=????-??-??T??:??:??[+-]????) ;; *) return 1 ;; esac
  [ "$intent_pid" = "$pid" ] && [ "$intent_identity" = "$identity" ]
}

fm_afk_stop_intent_retire() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3 path
  fm_afk_stop_intent_matches "$state" "$pid" "$identity" || return 1
  path=$(fm_afk_stop_intent_path "$state")
  rm -f "$path"
}

fm_afk_unexpected_exit_matches() {  # <state> <pid> <pid-identity>
  local state=$1 pid=$2 identity=$3 path line1 line2 line3 line4 exit_pid exit_identity lines
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
  case "$line3" in pid=*) exit_pid=${line3#pid=} ;; *) return 1 ;; esac
  case "$line4" in pid_identity=*) exit_identity=${line4#pid_identity=} ;; *) return 1 ;; esac
  [ "$exit_pid" = "$pid" ] && [ "$exit_identity" = "$identity" ]
}

fm_afk_unexpected_exit_record() {  # <state> <signal> <pid> <pid-identity>
  local state=$1 signal=$2 pid=$3 identity=$4 pending path
  case "$signal" in ''|*$'\n'*|*$'\r'*) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
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
  fm_afk_unexpected_exit_matches "$state" "$pid" "$identity" && return 2
  return 1
}
