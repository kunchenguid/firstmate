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

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged, or
#     unresolvable: no match (local work advanced outside the run, or the
#     branch tip was rewritten)
#
# Once the pipeline commits its own gate fixes, the run head exists ONLY in the
# no-mistakes bare gate repo (wired as the worktree's `no-mistakes` remote) and
# is not an object in the task worktree, so a worktree-only lookup rejected
# every live run past its first gate fix and attribution fell through to a
# stale prior run whose head still equalled the worktree HEAD - a LIVE run
# read as failed (the 2026-07-25 incident). When the worktree cannot resolve
# the head, resolve it in the gate repo and apply the same ancestry test
# there: the run's base was pushed to the gate when the run started, so a
# diverged or rewritten head still fails is-ancestor, and a worktree that
# advanced past the run head carries local commits the gate repo has never
# seen, which also fails. Both wrong-run rejections survive the widening.
# That widening reaches only a gate remote naming a local directory: `no-mistakes
# init` wires it as a bare path or as the same path in `file://` form, and both
# resolve here, while any other remote form leaves the head unresolvable and the
# run unattributed.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full repo
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  repo=$wt
  if ! run_full=$(git -C "$repo" rev-parse --verify "${run_head}^{commit}" 2>/dev/null); then
    repo=$(git -C "$wt" remote get-url no-mistakes 2>/dev/null) || return 1
    repo=${repo#file://}
    [ -d "$repo" ] || return 1
    run_full=$(git -C "$repo" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  fi
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$repo" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}
