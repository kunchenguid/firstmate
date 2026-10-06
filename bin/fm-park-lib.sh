#!/usr/bin/env bash
# fm-park-lib.sh - the park marker: firstmate's own record that a task was
# stopped on purpose and is queued, kept apart from the worker's status file.
#
# Contract (this file is the one owner of the format and the read rules):
#   state/<id>.parked is ONE line, `parked [at=<epoch>]: <reason>`, a regular
#   single-link file of mode 0700 that is not a symlink. bin/fm-park.sh writes
#   and clears it; nothing here or there ever touches state/<id>.status.
#   While it is valid, the watcher and the away daemon raise no declared-wait
#   recheck and no possible-wedge aging for the task, and the session-start
#   digest lists it under parked work. The next successful spawn or relaunch of
#   the task clears it (bin/fm-spawn.sh).
#
# fm_park_status <state-dir> <task> sets FM_PARK_REASON, FM_PARK_AT and
# FM_PARK_ERR and returns 0 (parked), 1 (no marker) or 2 (a marker exists but is
# malformed or unsafe). Callers must treat 2 as an alarm and never as absent,
# because absent silently restores the recheck noise this marker removes.
# No side effects on source; set -u / set -e safe.
# shellcheck disable=SC2034 # The FM_PARK_* results are read by the sourcing callers.

_fm_park_stat() {  # <format-gnu> <format-bsd> <path>
  stat -c "$1" "$3" 2>/dev/null || stat -f "$2" "$3" 2>/dev/null
}

fm_park_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]* | .*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_park_path() {  # <state-dir> <task>
  printf '%s/%s.parked\n' "$1" "$2"
}

fm_park_status() {  # <state-dir> <task>
  local state=$1 task=$2 f line links mode rest at reason
  FM_PARK_REASON='' FM_PARK_AT='' FM_PARK_ERR=''
  fm_park_valid_id "$task" || return 1
  f=$(fm_park_path "$state" "$task")
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    return 1
  fi
  if [ -L "$f" ] || [ ! -f "$f" ]; then
    FM_PARK_ERR="park marker $f is not a regular file"
    return 2
  fi
  links=$(_fm_park_stat %h %l "$f") || links=
  mode=$(_fm_park_stat %a %Lp "$f") || mode=
  if [ "$links" != 1 ]; then
    FM_PARK_ERR="park marker $f has link count '${links:-unknown}', expected 1"
    return 2
  fi
  if [ "$mode" != 700 ]; then
    FM_PARK_ERR="park marker $f has mode '${mode:-unknown}', expected 0700"
    return 2
  fi
  if [ "$(wc -l < "$f" 2>/dev/null | tr -d ' ')" != 1 ] || ! line=$(head -n 1 "$f" 2>/dev/null); then
    FM_PARK_ERR="park marker $f is not exactly one line"
    return 2
  fi
  case "$line" in
    'parked [at='[0-9]*']: '?*) ;;
    *) FM_PARK_ERR="park marker $f does not read 'parked [at=<epoch>]: <reason>'"; return 2 ;;
  esac
  rest=${line#'parked [at='}
  at=${rest%%']: '*}
  reason=${rest#*']: '}
  case "$at" in '' | *[!0-9]*) FM_PARK_ERR="park marker $f has a non-numeric time"; return 2 ;; esac
  case "$reason" in *[![:print:]]*) FM_PARK_ERR="park marker $f has a non-printable reason"; return 2 ;; esac
  [ -n "${reason//[[:space:]]/}" ] || { FM_PARK_ERR="park marker $f has an empty reason"; return 2; }
  FM_PARK_AT=$at
  FM_PARK_REASON=$reason
  return 0
}

# fm_park_clear <state-dir> <task>: remove the marker. Succeeds when none
# exists. A marker that cannot be removed is an error the caller must report.
fm_park_clear() {
  local f
  fm_park_valid_id "${2:-}" || return 1
  f=$(fm_park_path "$1" "$2")
  [ -e "$f" ] || [ -L "$f" ] || return 0
  rm -f -- "$f" && [ ! -e "$f" ] && [ ! -L "$f" ]
}
