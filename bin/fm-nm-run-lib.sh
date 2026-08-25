#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own. The rule is ternary
# (fm_nm_head_identity) because "cannot tell" is a third answer that must not be
# collapsed into either: a caller that acts on a run needs the strict predicate,
# while a caller that only REPORTS state needs to say unknown instead of a
# confident wrong verdict.
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

# Ternary code-identity verdict for run head $2 against worktree $1, printing
# exactly one token:
#   unbound    - no run head was reported, or the worktree has no readable HEAD;
#                there is nothing to bind, so there is no run to attribute
#   match      - the run's code identity is this worktree's current code
#   mismatch   - the run ran on code this worktree no longer holds
#   unverified - a real run head was reported, but identity can be neither
#                confirmed nor refuted from here
#
# The local rule answers first because it is free:
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of the run head: match (pipeline fix commits
#     on the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: mismatch
#     (local work advanced outside the run, or the branch tip was rewritten)
#
# A run head that does not resolve in this worktree's object database at all is
# the ROUTINE shape of a healthy in-flight run, not evidence against it: the
# pipeline commits its own fixes and pushes them to the configured target, so
# its tip is a real commit that was never fetched here. Treating that as a
# mismatch is a false negative that gets MORE likely the longer and harder a run
# works, which is why it is reported as `unverified` rather than folded into
# `mismatch` - callers must be able to tell "provably not mine" from "cannot
# tell". Optional $3 is the run's launch anchor (its submitted head, from
# fm_nm_submitted_head): the head the run was STARTED against, which is the head
# the worktree still holds while the pipeline advances its own. When it is
# supplied and resolves, it decides identity outright.
fm_nm_head_identity() {  # <worktree> <run_head> [<submitted_head>]
  local wt=$1 run_head=$2 anchor=${3:-} local_full run_full anchor_full
  [ -n "$run_head" ] || { printf 'unbound'; return 0; }
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'unbound'; return 0; }
  if run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null); then
    if [ "$run_full" = "$local_full" ] \
      || git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
      printf 'match'
    else
      printf 'mismatch'
    fi
    return 0
  fi
  [ -n "$anchor" ] || { printf 'unverified'; return 0; }
  anchor_full=$(git -C "$wt" rev-parse --verify "${anchor}^{commit}" 2>/dev/null) \
    || { printf 'unverified'; return 0; }
  if [ "$anchor_full" = "$local_full" ]; then printf 'match'; else printf 'mismatch'; fi
}

# The run's submitted head for worktree $1's current branch, read through the one
# read-only CLI surface that reports it. `no-mistakes axi sync --check` freshly
# verifies and returns the plan without changing HEAD, and its pipeline block
# carries submitted_head alongside current_head; `axi status` reports only the
# CURRENT head, and `no-mistakes runs` only the current head's short SHA, so
# neither can anchor identity on its own (verified against the installed
# v1.48.0). Echoes empty for every no-answer case - no CLI, no pipeline binding
# for this branch, or a bounded-out call - because none of them is a refutation.
fm_nm_submitted_head() {  # <worktree> <timeout_secs>
  local out
  command -v no-mistakes >/dev/null 2>&1 || return 0
  out=$(fm_nm_run "$1" "$2" axi sync --check) || return 0
  [ -n "$out" ] || return 0
  fm_nm_strip_quotes "$(fm_nm_field "$out" submitted_head)"
}

# 0 if run head $2 is provably worktree $1's own code identity. The strict
# predicate: only a verified `match` passes, so a caller that acts on a run
# (fm-teardown.sh's pre-teardown abort) never acts on one it cannot bind.
# Callers that must distinguish "cannot tell" from "not mine" read
# fm_nm_head_identity directly instead.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  [ "$(fm_nm_head_identity "$1" "$2")" = match ]
}
