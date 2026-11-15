#!/usr/bin/env bash
# fm-procevent-failure-wakes-lib.sh - the opt-in quiet record behind repeated
# `process-event source failed to start` wakes.
#
# Sourced, never executed. bin/fm-procevent.sh reconcile owns when a failure
# or a recovery is recorded and announced; bin/fm-fleet-snapshot.sh reads the
# records for the fleet view. docs/configuration.md "Process-event failure
# wakes" owns the home gate, its keys, and the wake policy.
#
# THE GATE (config/procevent-failure-wakes). Absent means off, and then nothing
# here is called and nothing is written. A present file enables it; its
# optional lines are
#   repeat-seconds=<n>      window after a failure wake that holds back later
#                           failure wakes of the same source and reason (3600)
#   recovered-wake=on|off   wake once when a source with held-back failures
#                           starts again (on)
# Blank lines, lines starting with #, unknown keys, and unusable values are
# ignored, so a malformed file keeps the defaults.
#
# THE RECORD ($STATE/procevent/.<source-id>.failure-quiet) is two lines:
#   v1 <reason> <window-start> <failures> <failing|recovered> <recovery-woke 0|1> <last-failure>
#   <reason text, printable, bounded>
# reason is a space-free token: launch-unconfirmed, launch-refused-<cksum>, or
# cleanup-refused. window-start is the epoch of the failure wake that opened
# the window. failures counts failed launches held back since that wake or the
# last recovery. recovery-woke records that this window already sent its one
# recovery wake. Epochs are seconds.
#
# THE LOG ($STATE/procevent/.failure-quiet.log) gets one line per held-back
# failure and is trimmed to its last FM_PFW_LOG_KEEP lines once it passes
# FM_PFW_LOG_MAX_BYTES.

FM_PFW_REPEAT_DEFAULT=3600
FM_PFW_RECOVERED_DEFAULT=on
FM_PFW_LOG_MAX_BYTES=65536
FM_PFW_LOG_KEEP=200
FM_PFW_TEXT_MAX=200

# fm_pfw_config <config-dir>: succeed and set FM_PFW_REPEAT and
# FM_PFW_RECOVERED_WAKE when the home opted in; fail when it did not.
fm_pfw_config() {
  local file=$1/procevent-failure-wakes line key value
  [ -f "$file" ] || return 1
  FM_PFW_REPEAT=$FM_PFW_REPEAT_DEFAULT
  FM_PFW_RECOVERED_WAKE=$FM_PFW_RECOVERED_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*|*=*=*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      repeat-seconds)
        # Nine digits keeps the sum with an epoch inside 64-bit arithmetic on
        # every supported bash.
        case "$value" in ''|0*|*[!0-9]*) continue ;; esac
        [ "${#value}" -le 9 ] || continue
        FM_PFW_REPEAT=$value
        ;;
      recovered-wake)
        case "$value" in on|off) FM_PFW_RECOVERED_WAKE=$value ;; esac
        ;;
    esac
  done < "$file"
  return 0
}

fm_pfw_record_path() { printf '%s/.%s.failure-quiet\n' "$1" "$2"; }  # <registry-dir> <source-id>
fm_pfw_log_path() { printf '%s/.failure-quiet.log\n' "$1"; }  # <registry-dir>

# fm_pfw_text <text>: print <text> as one printable line of at most
# FM_PFW_TEXT_MAX bytes.
fm_pfw_text() {
  local text
  text=$(printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ')
  printf '%s' "${text:0:$FM_PFW_TEXT_MAX}"
}

# fm_pfw_record_read <file>: set FM_PFW_REC_REASON, _START, _FAILURES, _STATE,
# _WOKE, _LAST, and _TEXT; fail when the record is absent or malformed.
fm_pfw_record_read() {
  local file=$1 head text version reason start failures state woke last extra
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  { IFS= read -r head || return 1; IFS= read -r text || true; } < "$file"
  read -r version reason start failures state woke last extra <<< "$head"
  [ "$version" = v1 ] && [ -z "$extra" ] || return 1
  case "$reason" in launch-unconfirmed|cleanup-refused|launch-refused-[0-9]*) ;; *) return 1 ;; esac
  case "$reason" in launch-refused-*[!0-9]*) return 1 ;; esac
  case "$start$failures$last" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$start" ] && [ -n "$failures" ] && [ -n "$last" ] || return 1
  case "$state" in failing|recovered) ;; *) return 1 ;; esac
  case "$woke" in 0|1) ;; *) return 1 ;; esac
  FM_PFW_REC_REASON=$reason
  FM_PFW_REC_START=$start
  FM_PFW_REC_FAILURES=$failures
  FM_PFW_REC_STATE=$state
  FM_PFW_REC_WOKE=$woke
  FM_PFW_REC_LAST=$last
  FM_PFW_REC_TEXT=$text
  return 0
}

# fm_pfw_record_write <file> <reason> <window-start> <failures> <state> <woke> <last> <text>
fm_pfw_record_write() {
  local file=$1 tmp
  tmp=$(umask 077; mktemp "$file.XXXXXX") || return 1
  if ! printf 'v1 %s %s %s %s %s %s\n%s\n' "$2" "$3" "$4" "$5" "$6" "$7" "$(fm_pfw_text "$8")" > "$tmp" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# fm_pfw_log <registry-dir> <line>: append one line to the bounded log.
fm_pfw_log() {
  local log size tmp
  log=$(fm_pfw_log_path "$1")
  (umask 077; printf '%s\n' "$(fm_pfw_text "$2")" >> "$log") || return 1
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -gt "$FM_PFW_LOG_MAX_BYTES" ] || return 0
  tmp=$(umask 077; mktemp "$log.XXXXXX") || return 0
  if tail -n "$FM_PFW_LOG_KEEP" "$log" > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$log" || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
}

# fm_pfw_utc <epoch>: print the epoch as an ISO-8601 UTC time, on GNU or BSD
# date, or the bare epoch when neither form is available.
fm_pfw_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s\n' "$1"
}

# fm_pfw_snapshot_json <registry-dir>: print a JSON array of readable records,
# sorted by source id, for the fleet snapshot.
fm_pfw_snapshot_json() {
  local reg=$1 file id
  {
    if [ -d "$reg" ]; then
      for file in "$reg"/.*.failure-quiet; do
        [ -e "$file" ] || continue
        id=${file##*/}; id=${id#.}; id=${id%.failure-quiet}
        fm_pfw_record_read "$file" || continue
        jq -cn --arg source "$id" --arg reason "$FM_PFW_REC_REASON" --arg text "$FM_PFW_REC_TEXT" \
          --arg state "$FM_PFW_REC_STATE" --arg since "$(fm_pfw_utc "$FM_PFW_REC_START")" \
          --arg last "$(fm_pfw_utc "$FM_PFW_REC_LAST")" \
          --argjson failures "$FM_PFW_REC_FAILURES" --argjson woke "$FM_PFW_REC_WOKE" \
          '{source:$source,reason:$reason,reason_text:$text,state:$state,held_failures:$failures,
            window_start:$since,last_failure:$last,recovery_woke:($woke == 1)}' || return 1
      done
    fi
  } | jq -cs 'sort_by(.source)'
}
