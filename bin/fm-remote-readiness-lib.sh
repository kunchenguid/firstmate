#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id> [bound-seconds]
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# The optional third argument bounds each of those runs by wall clock, for a
# caller that supervision waits on (the liveness probe passes
# FM_SECONDMATE_PROBE_TIMEOUT). A run abandoned at the bound returns 255, never
# 1: a host that accepts the connection and then hangs is unknown, not unready.
# Routed callers (bin/fm-spawn.sh's launch gate, bin/fm-remote-home-seed.sh)
# pass no bound, because `fm-remote-doctor.sh --fix` legitimately runs long.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete or a bounded run was abandoned. 255 means unknown remote
# completion, so a caller preserves its route and reconciles on the same host
# instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT holds the output of the last run, which carries the
# check lines, the remaining human: gaps, and their exact operator actions;
# a bounded run abandoned at its bound leaves it empty.

# FM_REMOTE_READINESS_OUT is consumed by the sourcing caller, so its every
# assignment reads as unused here; the directive below is file-wide because it
# precedes the first command.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_REMOTE_READINESS_LIB_DIR/fm-timeout-lib.sh"

FM_REMOTE_READINESS_OUT=

# One run whose output becomes FM_REMOTE_READINESS_OUT. An empty bound runs it
# unbounded, the way routed work runs; a positive bound abandons the run and its
# whole process group at the bound, returns 255, and discards its partial output
# unread, so a truncated doctor report can never stand in for a verdict.
fm_remote_readiness_step() { # <bin-dir> <secondmate-id> <bound-seconds|''> [doctor-args...]
  local bin_dir=$1 id=$2 bound=$3 out rc
  shift 3
  if [ -n "$bound" ]; then
    out=$(fm_exec_timed "$bound" 1 \
      "$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" < /dev/null 2>&1)
    rc=$?
    if fm_timed_out "$rc"; then
      FM_REMOTE_READINESS_OUT=
      return 255
    fi
  else
    out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" < /dev/null 2>&1)
    rc=$?
  fi
  FM_REMOTE_READINESS_OUT=$out
  return "$rc"
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id> [bound-seconds]
  local bin_dir=$1 id=$2 bound=${3:-} rc
  case "$bound" in ''|0*|*[!0-9]*) bound= ;; esac

  rc=0
  fm_remote_readiness_step "$bin_dir" "$id" "$bound" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  rc=0
  fm_remote_readiness_step "$bin_dir" "$id" "$bound" --fix || rc=$?
  [ "$rc" -ne 255 ] || return 255

  rc=0
  fm_remote_readiness_step "$bin_dir" "$id" "$bound" || rc=$?
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
