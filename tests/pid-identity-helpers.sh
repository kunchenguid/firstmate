#!/usr/bin/env bash
# tests/pid-identity-helpers.sh - fixtures for process identities recorded and
# checked across a host time-zone change (bin/fm-pid-identity-lib.sh). Sourced
# by tests/lib.sh and directly by suites that keep their own reporters; it has
# no source-time side effects.
#
# Two POSIX zones nine and seven hours from UTC, so a record made in one and
# checked in the other models a host time-zone change without needing tzdata.
# Set FM_PROC_ROOT_OVERRIDE to an empty directory as well so fm_pid_identity
# takes its ps path on Linux too.
# shellcheck disable=SC2034 # Read by the test scripts that source this file.
FM_TEST_TZ_EAST=JST-9
# shellcheck disable=SC2034 # Read by the test scripts that source this file.
FM_TEST_TZ_WEST=MST7

# fm_test_legacy_pid_identity <pid> <tz>: the identity a build before the UTC
# pin (bin/fm-pid-identity-lib.sh) recorded for <pid> while the host zone was
# <tz>: the bare local-time ps lstart and command line.
fm_test_legacy_pid_identity() {
  COLUMNS=10000 LC_ALL=C TZ="$2" ps -p "$1" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//'
}

# fm_test_shift_legacy_identity <legacy-identity> <seconds>: the same record
# with its leading 24-character lstart date moved by <seconds>.
fm_test_shift_legacy_identity() {
  local stamp=${1:0:24} rest=${1:24} seconds format='%a %b %e %H:%M:%S %Y'
  seconds=$(TZ=UTC0 LC_ALL=C date -j -f "$format" "$stamp" +%s 2>/dev/null \
    || TZ=UTC0 LC_ALL=C date -d "$stamp" +%s 2>/dev/null) || return 1
  seconds=$((seconds + $2))
  stamp=$(TZ=UTC0 LC_ALL=C date -r "$seconds" "+$format" 2>/dev/null \
    || TZ=UTC0 LC_ALL=C date -d "@$seconds" "+$format" 2>/dev/null) || return 1
  printf '%s%s\n' "$stamp" "$rest"
}

# fm_test_identity_record <pid> <form> <tz> <no-proc-dir>: the identity an
# owner recorded for <pid> while the host zone was <tz>. Form "current" is this
# build's fm_pid_identity on its ps path, "legacy" the bare local-time form.
fm_test_identity_record() {
  if [ "$2" = legacy ]; then
    fm_test_legacy_pid_identity "$1" "$3"
    return
  fi
  TZ="$3" FM_PROC_ROOT_OVERRIDE="$4" FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$1"
}

# fm_test_wait_exec <pid> <command-fragment>: wait up to five seconds until
# <pid> runs a command line containing <command-fragment>. A child read between
# its fork and its exec still carries the forking shell's command line, so an
# identity recorded then would never match the child it names.
fm_test_wait_exec() {
  local i=0
  while [ "$i" -lt 100 ]; do
    case "$(ps -p "$1" -o command= 2>/dev/null)" in *"$2"*) return 0 ;; esac
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}
