#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity and repository-scope rules that decide
# whether a no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
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

# The no-mistakes REPOSITORY SCOPE for worktree $1: the main worktree behind
# git-common-dir. Non-zero when $1 is not inside a git repository.
#
# One owner, because two callers must agree exactly. `no-mistakes runs` lists
# runs for the CURRENT REPOSITORY, and the CLI resolves a linked worktree to the
# clone it was registered under (verified against the installed CLI, v1.51.1:
# `runs` inside a treehouse worktree lists the registered clone's runs). Every
# ship task gets its OWN isolated worktree leased from that clone
# (bin/fm-spawn.sh's validate_spawn_worktree refuses anything else), so the
# worktree root is a private key that shares nothing while the main worktree is
# the scope the CLI itself answers for. bin/fm-fleet-snapshot.sh stamps a
# collected inventory with this scope and bin/fm-crew-state.sh reuses that
# inventory only when its own computation is string-equal, so a divergence
# between two copies of this rule would silently disable reuse everywhere with
# no test failure - the fallback is a legal bounded query.
fm_nm_repo_scope() {  # <worktree>
  local common
  common=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *) common=$(cd "$1" 2>/dev/null && cd "$common" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  [ -n "$common" ] || return 1
  ( cd "$(dirname "$common")" 2>/dev/null && pwd -P ) || return 1
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

# The ci step row's own status inside captured `axi status` output $1, or empty
# when the steps table has no active ci row.
fm_nm_ci_step_row_status() {  # <toon-output>
  local row rest
  row=$(printf '%s\n' "$1" \
    | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' \
    | head -1)
  [ -n "$row" ] || return 0
  row=$(fm_nm_trim "$row")
  rest=${row#*,}
  fm_nm_strip_quotes "$(fm_nm_trim "${rest%%,*}")"
}

# ONE owner for "is this run in the ci phase, and in which sub-state" - the
# question bin/fm-crew-state.sh asks to decide whether to read the ci step log at
# all, and the question bin/fm-fleet-snapshot.sh's home summary asks to decide
# whether to COLLECT that log up front for a child. Two copies of this rule can
# only diverge in one direction that matters: a collector narrower than the
# reader hands the reader a set-but-empty log, which pins a green-CI child at
# `unknown` readiness instead of letting it fall back to its own query.
#
# Answers "running", "fixing", or empty (not a ci-phase run), given the captured
# output $1 and the run's own top-level status $2. Top-level `fixing` wins
# because it describes the whole run, then the steps table, then a top-level
# `ci` with no steps table at all.
fm_nm_effective_ci_step_status() {  # <toon-output> <top-level-status>
  local step_status
  if [ "${2:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(fm_nm_ci_step_row_status "$1")
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${2:-}" = ci ]; then
    printf 'running'
  fi
}
