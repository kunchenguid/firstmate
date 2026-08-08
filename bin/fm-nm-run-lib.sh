#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the rule that decides whether a no-mistakes run belongs to a
# given worktree, used by fm-crew-state.sh (read-only current-state reporting)
# and fm-teardown.sh (pre-teardown run abort, see its "Fix 1" header comment).
# Getting this wrong in either direction is unsafe: a false negative hides a
# genuinely parked run, and a false positive lets teardown act on a run it does
# not own. fm_nm_run_binds_worktree is that rule and is what callers ask; it
# combines two bindings, both requiring this worktree's own branch:
# fm_nm_head_matches_worktree compares code identity by sha, and
# fm_nm_pipeline_owns_worktree reads no-mistakes' own branch_sync verdict for
# the case the sha rule cannot decide - a run whose head lives only in the gate.
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

# Scalar value of a key nested under one top-level TOON block of $1. `axi status`
# reuses bare key names across blocks - run.head and branch_sync.local.head both
# render as `head:` - so fm_nm_field's whole-output first-match scan cannot
# address them; this bounds the scan to the named block.
fm_nm_block_field() {  # <toon-output> <block> <key>
  printf '%s\n' "$1" \
    | sed -n "/^$2:[[:space:]]*$/,/^[^[:space:]]/p" \
    | sed -n "s/^[[:space:]]*$3:[[:space:]]*\(.*\)/\1/p" \
    | head -1
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

# 0 when `axi status` output $4 reports that the pipeline currently owns worktree
# $1's branch $2, which attributes run id $3 to that worktree without needing the
# run head to be resolvable there.
#
# The head rule above cannot answer that case at all. A run in flight commits its
# fixes inside the gate repo (~/.no-mistakes/repos/<id>.git), a separate object
# store that publishes to the crew's checkout only on custody return, so while
# the pipeline owns the branch `run.head` names a commit the worktree does not
# have and rev-parse fails. Rejecting there sends the caller to a coarse
# branch-and-recency lookup that can then attribute an OLDER, superseded run on
# the same branch whose head the worktree does have (verified 2026-08-07: run
# 01KZEXVBYW5FFWXMPZ1MTXHP31 was running while the reader reported the failed run
# that preceded it on the same branch).
#
# branch_sync (verified against the installed v1.41.2, which reports it for every
# run) is computed by no-mistakes inside that same worktree, so it is the
# authoritative binding rather than a relaxation: this still requires the
# worktree's own branch, its exact current HEAD, and the run id branch_sync
# itself names. state=pipeline_owned means a run holds the branch and has not
# returned custody; a historical run on a reused branch whose head was rewritten
# or advanced past carries some other state instead (verified live: a crew that
# committed on top of its finished run reads local_ahead), so it stays
# unattributed exactly as the sha rule already decided.
fm_nm_pipeline_owns_worktree() {  # <worktree> <branch> <run_id> <toon-output>
  local wt=$1 branch=$2 run_id=$3 out=$4 sync_state sync_branch sync_run sync_head sync_full local_full
  [ -n "$branch" ] && [ -n "$run_id" ] || return 1
  sync_state=$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync state)")
  [ "$sync_state" = pipeline_owned ] || return 1
  sync_branch=$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync branch)")
  [ "$sync_branch" = "$branch" ] || return 1
  sync_run=$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync run)")
  [ "$sync_run" = "$run_id" ] || return 1
  sync_head=$(fm_nm_strip_quotes "$(fm_nm_block_field "$out" branch_sync head)")
  [ -n "$sync_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  sync_full=$(git -C "$wt" rev-parse --verify "${sync_head}^{commit}" 2>/dev/null) || return 1
  [ "$sync_full" = "$local_full" ]
}

# 0 when the run `axi status` output $5 describes - id $3, head $4 - belongs to
# worktree $1 on branch $2. THE attribution question, asked as one call so both
# readers decide identically: fm-crew-state.sh judging a crew's current state and
# fm-teardown.sh deciding whether a run parked at a gate is this task's to abort.
# Callers must still confirm the run's branch field matches; both bindings below
# are about code identity, not about which branch the run names.
#
# The sha binding answers a run whose head this worktree has. The
# pipeline-ownership binding answers the run whose head it does not - the shape
# of every run still holding custody - which is why asking only the sha binding
# reads a live run as no run at all.
fm_nm_run_binds_worktree() {  # <worktree> <branch> <run_id> <run_head> <toon-output>
  fm_nm_head_matches_worktree "$1" "$4" && return 0
  fm_nm_pipeline_owns_worktree "$1" "$2" "$3" "$5"
}
