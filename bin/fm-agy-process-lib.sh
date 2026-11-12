#!/usr/bin/env bash
# agy (Antigravity CLI) process identity, shared by harness detection, the
# session-lock ancestry walk, and agent liveness. This file has no side effects
# on source.
#
# agy is a Go-compiled single binary. Linux names a process after the file name
# it was executed by, so the same binary reports different process names:
#   - `agy` when started through that name (verified, agy 1.2.0: comm=agy with
#     argv[0]=agy);
#   - `antigravity` when started through its real file name, which a mise
#     install ships as .../antigravity-cli/<ver>/antigravity with `agy` a
#     symlink to it (verified, agy 1.5.6 via mise);
#   - `exe` for its Linux command-sandbox init, re-executed through
#     /proc/self/exe while argv[0] keeps the binary path.
# `antigravity` is also the process name of the Antigravity IDE (an Electron
# app installed as /usr/bin/antigravity or /usr/share/antigravity/antigravity),
# and `exe` is generic, so those two names count only with CLI evidence in
# argv[0]: a basename of exactly `agy`, or a path component named exactly
# `antigravity-cli`. A bare name with no argv[0] is never agy.
fm_agy_process_matches() {  # <comm> <argv0>
  local comm=${1:-} argv0=${2:-}
  case "${comm##*/}" in
    agy) return 0 ;;
    antigravity|exe) ;;
    *) return 1 ;;
  esac
  [ -n "$argv0" ] || return 1
  [ "${argv0##*/}" = agy ] && return 0
  case "/$argv0/" in
    */antigravity-cli/*) return 0 ;;
  esac
  return 1
}
