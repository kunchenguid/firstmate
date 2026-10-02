#!/usr/bin/env bash
# fm-pid-identity-lib.sh - process identities that no time-zone change moves,
# with no source-time side effects, so a library without the wake library's
# state setup (the remote job worker) can load the same definition.
#
# An identity proves that a recorded pid still names the process that recorded
# it, across PID reuse: the process start time plus its full command line.
# The Linux-compatible /proc form uses stat field 22 (starttime, clock ticks
# since boot), which no clock step or zone change moves. The portable ps form
# reads lstart, which ps renders in the local time zone, so it is read under
# TZ=UTC0 and keyed "lstart-utc=". Builds before that pin recorded the bare
# local-time rendering; fm_pid_identity_matches is the single owner of
# comparing a recorded identity with a live pid, including that legacy form.
#
# bin/fm-extension.mjs and bin/fm-pid-identity.mjs mirror the keyed form and
# the legacy rule for the extension host, which re-reads shell-recorded claims.
# Other ps lstart readers that keep their own record shape (the remote job
# worker, teardown, and the labs) pin the same TZ=UTC0; the remote job worker
# and the labs also read their pre-pin records through
# fm_pid_identity_legacy_matches.

# Print <pid>'s lstart and command line as ps renders them in UTC under the C
# locale, with leading blanks removed. LC_ALL=C keeps the date format
# locale-invariant, and the wide COLUMNS keeps a narrow-terminal caller from
# cutting the command short (issue #799).
_fm_pid_ps_utc() {  # <pid>
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(COLUMNS=10000 LC_ALL=C TZ=UTC0 ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  out=${out#"${out%%[![:space:]]*}"}
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_pid_identity() {  # <pid>
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer a Linux-compatible /proc when present: its starttime is also immune
  # to the wall-clock steps that re-render the ps lstart date (observed as WSL2
  # btime drift), and the full NUL-separated cmdline keeps PID reuse a mismatch
  # even on a tick collision. Git Bash/MSYS exposes these compatible files but
  # its Cygwin ps rejects the portable -o fields, so capability detection must
  # not key on uname.
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    [ -n "${_FM_UNAME:-}" ] || _FM_UNAME=$(uname 2>/dev/null || echo unknown)
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  out=$(_fm_pid_ps_utc "$pid") || return 1
  printf 'lstart-utc=%s\n' "$out"
}

# Parse the lstart date ("Fri Oct  2 15:14:48 2026", C locale) that begins
# <text>. Sets _FM_PID_LSTART_SECONDS to the seconds it names when read as UTC,
# and _FM_PID_LSTART_REST to the text after it with tabs, carriage returns, and
# newlines flattened to spaces and outer blanks trimmed. Fails when <text> does
# not begin with such a date.
_FM_PID_LSTART_SECONDS=
_FM_PID_LSTART_REST=
_fm_pid_lstart_parse() {  # <text>
  local re='^[[:space:]]*[A-Z][a-z][a-z] ([A-Z][a-z][a-z]) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4})(.*)$'
  local month year day era yoe doy rest
  [[ $1 =~ $re ]] || return 1
  case "${BASH_REMATCH[1]}" in
    Jan) month=1 ;; Feb) month=2 ;; Mar) month=3 ;; Apr) month=4 ;;
    May) month=5 ;; Jun) month=6 ;; Jul) month=7 ;; Aug) month=8 ;;
    Sep) month=9 ;; Oct) month=10 ;; Nov) month=11 ;; Dec) month=12 ;;
    *) return 1 ;;
  esac
  year=$((10#${BASH_REMATCH[6]}))
  day=$((10#${BASH_REMATCH[2]}))
  # Days from 1970-01-01 to the civil date (Hinnant's days_from_civil).
  [ "$month" -gt 2 ] || year=$((year - 1))
  era=$((year / 400))
  yoe=$((year - era * 400))
  if [ "$month" -gt 2 ]; then
    doy=$(((153 * (month - 3) + 2) / 5 + day - 1))
  else
    doy=$(((153 * (month + 9) + 2) / 5 + day - 1))
  fi
  _FM_PID_LSTART_SECONDS=$((((era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy) - 719468) * 86400 \
    + 10#${BASH_REMATCH[3]} * 3600 + 10#${BASH_REMATCH[4]} * 60 + 10#${BASH_REMATCH[5]}))
  rest=${BASH_REMATCH[7]//[$'\t\r\n']/ }
  rest=${rest#"${rest%%[! ]*}"}
  _FM_PID_LSTART_REST=${rest%"${rest##*[! ]}"}
}

# fm_pid_identity_legacy_matches <recorded> <utc-text>
# True when <recorded> is the unkeyed local-time form a build before the UTC
# pin wrote, and it names the same process as <utc-text>, the same ps fields
# rendered in UTC. The text after the date must be identical once blanks are
# flattened, and the two dates must differ by a whole quarter hour between
# -12:00 and +14:00, the range every civil zone offset falls in. So a live
# owner recorded before an upgrade still matches after any zone change, while
# PID reuse still mismatches unless an identical command line restarts on that
# exact pid at a quarter-hour-aligned second. Keyed records never reach this
# rule, so it retires with the last owner a pre-upgrade build recorded.
fm_pid_identity_legacy_matches() {  # <recorded> <utc-text>
  local recorded_seconds recorded_rest offset
  _fm_pid_lstart_parse "$1" || return 1
  recorded_seconds=$_FM_PID_LSTART_SECONDS
  recorded_rest=$_FM_PID_LSTART_REST
  _fm_pid_lstart_parse "$2" || return 1
  [ "$recorded_rest" = "$_FM_PID_LSTART_REST" ] || return 1
  offset=$((recorded_seconds - _FM_PID_LSTART_SECONDS))
  [ $((offset % 900)) -eq 0 ] || return 1
  [ "$offset" -ge -43200 ] && [ "$offset" -le 50400 ]
}

# fm_pid_identity_matches <pid> <recorded>
# 0 when <pid> is still the process <recorded> names, 1 when it is not (or
# <recorded> is empty), 2 when <pid>'s identity cannot be read now. A keyed
# record must match exactly; an unkeyed legacy record is checked against the
# UTC rendering by fm_pid_identity_legacy_matches.
fm_pid_identity_matches() {  # <pid> <recorded>
  local pid=$1 recorded=$2 current utc
  current=$(fm_pid_identity "$pid" 2>/dev/null) && [ -n "$current" ] || return 2
  [ -n "$recorded" ] || return 1
  [ "$current" = "$recorded" ] && return 0
  case "$current" in
    lstart-utc=*) utc=${current#lstart-utc=} ;;
    *)
      # A /proc host compares a legacy ps record (an older pending-reply
      # sender) against the ps rendering, read only for that record shape.
      _fm_pid_lstart_parse "$recorded" || return 1
      utc=$(_fm_pid_ps_utc "$pid") || return 2
      ;;
  esac
  fm_pid_identity_legacy_matches "$recorded" "$utc" && return 0
  return 1
}
