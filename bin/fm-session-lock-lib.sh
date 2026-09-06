#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# This file keeps only the lock-ownership helper and sources the shared
# side-effect-free harness process-identity owner.

# shellcheck source=bin/fm-harness-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-harness-process-lib.sh"

# Preserve the shared owner and extend only the primary/session-lock surface it
# does not yet name: omp (Oh My Pi). omp is anchored exactly like pi: its live
# process name is the bare word `omp` (verified, omp 18.1.11), and a substring
# match would claim unrelated commands such as ompd or comp.
eval "$(declare -f fm_harness_process_matches | sed '1s/fm_harness_process_matches/fm_harness_process_matches_base/')"
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_MATCH_NAME=
  base=$(basename -- "$comm")
  case "$base" in
    omp) FM_HARNESS_MATCH_NAME=omp; return 0 ;;
  esac
  argv0=${args%% *}
  case "/$comm/" in
    */omp/*) FM_HARNESS_MATCH_NAME=omp; return 0 ;;
  esac
  case "/$argv0/" in
    */omp/*) FM_HARNESS_MATCH_NAME=omp; return 0 ;;
  esac
  fm_harness_process_matches_base "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
