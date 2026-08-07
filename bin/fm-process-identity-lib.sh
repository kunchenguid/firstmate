#!/usr/bin/env bash
# Shared process-reuse identity for spawn and teardown.
# Sourced by bin/fm-spawn.sh and bin/fm-teardown.sh.
# This file is sourced by scripts and has no side effects on source.
#
# The identity recorded at spawn is re-checked at teardown so a recycled pid
# is never mistaken for the process that was recorded.
#
# Linux /proc/<pid>/stat is authoritative when readable. The parse must strip
# through the FINAL `)` before splitting, because field 2 is the parenthesized
# comm and a comm containing spaces (or parentheses) shifts every positional
# field after it - reading `$22` from the raw line records the wrong number and
# silently breaks the recycled-pid check. `starttime` is field 22 overall,
# which is index 19 of the remainder after the comm.
#
# `ps -o lstart=` is the portable fallback for platforms without /proc. Both
# forms are self-describing, so a recorded value always states which it is.
#
# Distinct from fm_pid_identity in bin/fm-wake-lib.sh, which uses a different
# wire format for watcher lock semantics.

# shellcheck shell=bash

fm_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

fm_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}
