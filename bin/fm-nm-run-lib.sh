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

# Scalar value of key $3 inside the `$2:` sub-block of the top-level
# `branch_sync:` block of `axi status` output $1 (e.g. section `pipeline`, key
# `submitted_head`). Scoped because branch_sync repeats key names the run block
# already uses - `head`, `status`, `run`, `branch` - so the unscoped fm_nm_field
# above would answer from the wrong block. Section and key are literal
# identifiers supplied by callers, never user data.
fm_nm_branch_sync_field() {  # <toon-output> <section> <key>
  printf '%s\n' "$1" \
    | sed -n '/^branch_sync:[[:space:]]*$/,/^[^[:space:]]/p' \
    | sed -n "/^  $2:[[:space:]]*\$/,/^  [^[:space:]]/p" \
    | sed -n "s/^    $3:[[:space:]]*\(.*\)/\1/p" \
    | head -1
}

# Code-identity verdict for run head $2 against worktree $1. THREE outcomes,
# because "the run head is not an object in this worktree" and "the run head is
# a different line of history" are different facts and only the second is
# evidence that the run does not belong here:
#   0 match       - equal commits (short or full SHA), or worktree HEAD is an
#                   ancestor of the run head (pipeline fix commits on the same
#                   history advanced the run tip past local HEAD)
#   1 mismatch    - both commits resolve here and the run head is a strict
#                   ancestor of worktree HEAD or diverged from it (local work
#                   advanced outside the run, or the branch tip was rewritten);
#                   also the unbindable inputs: missing head, unreadable worktree
#   2 unresolvable - the run head is not an object in this worktree at all. The
#                   routine cause is a pipeline committing in the gate's own
#                   copy; even after the gate pushes to the remote, those commits
#                   remain absent here until fetched. NOT evidence of
#                   non-ownership: callers must corroborate from another binding
#                   (fm_nm_branch_sync_field above) or stay conservative, but
#                   must never read it as divergence.
# Callers using plain `|| return 1` therefore keep the pre-tri-state behavior of
# refusing to bind on an unresolvable head.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 2
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null || return 1
}
