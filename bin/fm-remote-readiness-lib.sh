#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id> [read-only]
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# The optional `read-only` third argument makes the gate read-only: it runs the
# first read-only check exactly once and returns its verdict without ever
# invoking the doctor's --fix repair, so a caller that must not run a
# service-repair fallback can still require a ready host. It changes only this
# readiness gate; a caller still performs its own work when the gate returns 0.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id> [read-only]
  local bin_dir=$1 id=$2 out rc repair=1
  [ "${3:-}" != read-only ] || repair=0

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255
  [ "$repair" -eq 1 ] || return 1

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
