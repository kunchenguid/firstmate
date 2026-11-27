#!/usr/bin/env bash
# fm-remote-call-lib.sh - the single owner of bounded remote fm-on.sh calls.
#
# Sourced, never executed. Every supervision-side remote call goes through
# fm_remote_call so one bound governs all of them: a host that accepts the SSH
# connection and then never answers costs at most that bound per call instead of
# stalling a whole supervision cycle. bin/fm-on.sh's own SSH keepalives only
# cover a link that was established and then dropped, so a peer whose sshd stays
# up while its command never returns would otherwise block indefinitely.
#
#   FM_REMOTE_CALL_TIMEOUT
#       Hard bound in seconds on one remote call. Defaults to 15, which sits
#       above bin/fm-on.sh's own SSH ConnectTimeout (10) so a merely unreachable
#       host still reports its own transport failure (255) instead of being
#       preempted here, while three silent mates still fit inside one
#       supervision cycle. Any value that is not a positive integer falls back
#       to the default rather than disabling the bound.
#
#   fm_remote_call <fm-on-path> [args...]
#       Runs one remote call with stdin closed and remote stderr discarded.
#       Returns the call's own status unchanged, except that the bound firing
#       reports 124 or 137 - exactly what fm_timed_out accepts - so a caller
#       keeps its existing 255 and other-status branches untouched and adds one
#       timeout branch beside them, treating it as remote-unavailable rather
#       than as evidence about the remote endpoint. Populates:
#
#         FM_REMOTE_CALL_OUT      the call's stdout, empty on failure
#         FM_REMOTE_CALL_ELAPSED  whole seconds the call actually spent
#
#       A timeout diagnostic names the endpoint and FM_REMOTE_CALL_ELAPSED, so
#       the time spent waiting is visible wherever the caller records its
#       verdict instead of only being inferable from the bound.
set -u

FM_REMOTE_CALL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_REMOTE_CALL_LIB_DIR/fm-timeout-lib.sh"

FM_REMOTE_CALL_TIMEOUT=${FM_REMOTE_CALL_TIMEOUT:-15}
case "$FM_REMOTE_CALL_TIMEOUT" in
  '' | 0* | *[!0-9]*) FM_REMOTE_CALL_TIMEOUT=15 ;;
esac

# Output globals read by sourcing callers.
# shellcheck disable=SC2034
FM_REMOTE_CALL_OUT=''
FM_REMOTE_CALL_ELAPSED=0

fm_remote_call() {  # <fm-on-path> [args...]
  local started rc=0
  started=$(date +%s)
  # Output globals read by sourcing callers.
  # shellcheck disable=SC2034
  FM_REMOTE_CALL_OUT=$(fm_run_timed "$FM_REMOTE_CALL_TIMEOUT" "$@" < /dev/null 2>/dev/null) || rc=$?
  # shellcheck disable=SC2034
  FM_REMOTE_CALL_ELAPSED=$(( $(date +%s) - started ))
  return "$rc"
}
