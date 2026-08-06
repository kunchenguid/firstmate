#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# What this file owns is reading and attributing the run record. Bounding the
# call is owned by bin/fm-timeout-lib.sh, which declares itself the single owner
# of bounded command execution, so the mechanism selection is not re-derived
# here. That matters beyond tidiness: its selection ends in a dependency-free
# bash watchdog, so a host with no timeout, gtimeout or perl still gets the same
# hard bound and process-group cleanup instead of an unbounded call or a refusal.
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status, where 124 means the bound was
# hit; the checked form discards stderr, while fm_nm_run keeps the fail-open
# query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2
  shift 2
  ( cd "$dir" && fm_run_timed "$timeout_secs" no-mistakes "$@" )
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Names of the steps a run has completed, one per line, read from the
# steps[N]{step,status,...} table in captured `axi status` output $1. The table
# ends at the next key line, so a scalar or a later block is never read as a row.
fm_nm_completed_steps() {  # <toon-output>
  printf '%s\n' "$1" | awk '
    /steps\[[0-9]+\]\{/ { in_steps = 1; next }
    !in_steps { next }
    /^[ \t]*[A-Za-z_]+[:[]/ { in_steps = 0; next }
    {
      row = $0
      sub(/^[ \t]+/, "", row)
      if (split(row, f, ",") < 2) next
      gsub(/[ \t"]/, "", f[1])
      gsub(/[ \t"]/, "", f[2])
      if (f[2] == "completed") print f[1]
    }
  '
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}
