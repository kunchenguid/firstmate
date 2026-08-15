#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the matching rules that decide whether a no-mistakes run
# belongs to a given worktree, used by fm-crew-state.sh (read-only
# current-state reporting) and fm-teardown.sh (pre-teardown run abort, see its
# "Fix 1" header comment). Getting this wrong in either direction is unsafe: a
# false negative hides a genuinely parked run, and a false positive lets
# teardown act on a run it does not own.
#
# Two rules live here. fm_nm_head_matches_worktree is the pure code-identity
# ancestry test. fm_nm_run_matches_worktree layers pipeline custody on top of
# it for callers that know the run's status, and is the one to use when
# reporting a branch's current state.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
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

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - run head not in the worktree's object store: cannot bind; reject
#     (fm_nm_run_matches_worktree below decides what an unreadable head means)
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

# 0 if run head $2 is a commit the worktree $1 can actually read, so the
# ancestry rules above have something to decide against.
fm_nm_head_is_readable() {  # <worktree> <run_head>
  local wt=$1 run_head=$2
  [ -n "$run_head" ] || return 1
  git -C "$wt" rev-parse --verify --quiet "${run_head}^{commit}" >/dev/null 2>&1
}

# 0 if run status word $1 names a run the pipeline is still driving, 1 once it
# names history. `no-mistakes` carries a run as `pending` then `running` for as
# long as it owns the branch, and as `completed`, `failed`, or `cancelled`
# afterwards; `axi status` reports the finer in-flight step word in the same
# field. The list is a whitelist, so an unrecognized future word reads as
# history and leaves the strict code-identity answer standing rather than
# being trusted as a live run on no evidence.
fm_nm_run_status_is_live() {  # <status-word>
  case "${1:-}" in
    pending|running|fixing|ci|awaiting_approval|fix_review) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the run with head $2 and status $3 is worktree $1's CURRENT run. Callers
# must already have established that the run is on this worktree's branch;
# this decides the code-identity half.
#
# Whenever the worktree can read the run head, the ancestry rules in
# fm_nm_head_matches_worktree decide, and a rewritten or diverged tip is
# refused exactly as before.
#
# An UNREADABLE run head is the case that needs deciding, because it is the
# normal shape of a healthy in-flight run rather than a sign of trouble: the
# pipeline commits its own gate fixes into its private gate repository
# (~/.no-mistakes/repos/<id>.git) and does not publish them to the crew's
# checkout at all until its push step, so from the worktree those commits
# simply do not exist yet. A live run holds custody of this exact branch in
# this exact repository right now, which is a stronger statement of ownership
# than any local ancestry proof, so it is attributed. A terminal run is
# history, and history that cannot be bound to the worktree's code is exactly
# what a stale-outcome misattribution is made of, so it is refused.
fm_nm_run_matches_worktree() {  # <worktree> <run_head> <run_status>
  local wt=$1 run_head=$2 run_status=${3:-}
  [ -n "$run_head" ] || return 1
  if fm_nm_head_is_readable "$wt" "$run_head"; then
    fm_nm_head_matches_worktree "$wt" "$run_head"
    return
  fi
  fm_nm_run_status_is_live "$run_status"
}
