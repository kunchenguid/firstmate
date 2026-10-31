#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id> [harness]
#
# When <harness> is a non-empty harness name, it is forwarded to the doctor as
# --harness on every doctor invocation, so the doctor gates Claude first-run
# onboarding on the harness the parent launch actually selected rather than on
# the remote home's own config. A seed preflight has no harness yet and passes
# none, leaving the doctor to gate onboarding on the account pin alone.
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id> [harness]
  local bin_dir=$1 id=$2 harness=${3:-} out rc
  local hargs=()
  [ -z "$harness" ] || hargs=(--harness "$harness")

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "${hargs[@]+"${hargs[@]}"}" < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "${hargs[@]+"${hargs[@]}"}" --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "${hargs[@]+"${hargs[@]}"}" < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
