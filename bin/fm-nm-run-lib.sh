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
# Two rules live here: fm_nm_head_matches_worktree (run head vs local HEAD) and
# fm_nm_status_binds_worktree (no-mistakes' own branch_sync binding, which
# still holds once the pipeline pushes a head the crew never fetched).
# fm_nm_status_matches_worktree composes them and records which callers take
# which.
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

# Scalar value of TOON key $4 nested under top-level block $2's child block $3
# in captured output $1, e.g. branch_sync -> pipeline -> submitted_head. The
# flat fm_nm_field above is nesting-blind and would answer `run`, `branch`, and
# `head` from the top-level run: block instead, so every branch_sync read goes
# through this scoped reader. Empty when the block or key is absent.
fm_nm_nested_field() {  # <toon-output> <parent> <child> <key>
  printf '%s\n' "$1" | awk -v parent="$2" -v child="$3" -v key="$4" '
    { line = $0; sub(/\r$/, "", line); match(line, /^[ \t]*/); ind = RLENGTH
      body = substr(line, ind + 1) }
    body == "" { next }
    ind == 0 { in_parent = (body == parent ":"); in_child = 0; next }
    !in_parent { next }
    !in_child { if (body == child ":") { in_child = 1; child_ind = ind } ; next }
    ind <= child_ind { in_child = 0; next }
    index(body, key ":") == 1 {
      v = substr(body, length(key) + 2)
      sub(/^[ \t]+/, "", v)
      print v
      exit
    }
  '
}

# 0 when no-mistakes itself reports that `axi status` output $2 describes the
# run that currently owns worktree $1's branch.
#
# Needed because fm_nm_head_matches_worktree alone inverts the identity rule
# for the NORMAL steady state of a no-mistakes run: the pipeline rebases and
# commits its own fixes in its gate repo, so the run head advances to a commit
# the crew's worktree has never fetched. `git rev-parse` cannot resolve that
# object at all, so head matching fails for the live run while an OLDER
# terminal run left at the untouched worktree head still matches - reporting a
# healthy crew as `failed` (observed 2026-08-12 on two live crews).
#
# `axi status` emits a branch_sync: block whenever the invoking worktree's
# current branch is bound to a pipeline run (verified 2026-08-12 against the
# installed v1.46.0, in both phases: pre_push, before any push binding exists,
# and after the push, while the ci step monitors the PR - an older CLI that
# emits no branch_sync simply falls back to the head rule). Its
# pipeline.submitted_head is the head the crew HANDED to that run, which is
# exactly this worktree's code identity, and its local.head is a fresh read of
# this worktree's HEAD.
#
# All of these must hold, so the binding cannot be borrowed from another crew:
#   - branch_sync.pipeline.run names the same run the output reports
#   - branch_sync.local.branch is that run's branch (callers require it to be
#     this worktree's branch too)
#   - branch_sync.local.head resolves to this worktree's current HEAD, so the
#     snapshot describes the code that is checked out right now
#   - branch_sync.pipeline.submitted_head is this worktree's HEAD, or an
#     ancestor of it (the crew committed on top of what it submitted)
fm_nm_status_binds_worktree() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 run_id bs_run run_branch bs_branch bs_head bs_submitted
  local local_full bs_head_full submitted_full
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$run_id" ] || return 1
  bs_run=$(fm_nm_strip_quotes "$(fm_nm_nested_field "$out" branch_sync pipeline run)")
  [ -n "$bs_run" ] && [ "$bs_run" = "$run_id" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  bs_branch=$(fm_nm_strip_quotes "$(fm_nm_nested_field "$out" branch_sync local branch)")
  [ -n "$run_branch" ] && [ "$bs_branch" = "$run_branch" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  bs_head=$(fm_nm_strip_quotes "$(fm_nm_nested_field "$out" branch_sync local head)")
  bs_head_full=$(git -C "$wt" rev-parse --verify "${bs_head:-}^{commit}" 2>/dev/null) || return 1
  [ "$bs_head_full" = "$local_full" ] || return 1
  bs_submitted=$(fm_nm_strip_quotes "$(fm_nm_nested_field "$out" branch_sync pipeline submitted_head)")
  submitted_full=$(git -C "$wt" rev-parse --verify "${bs_submitted:-}^{commit}" 2>/dev/null) || return 1
  [ "$submitted_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$submitted_full" "$local_full" 2>/dev/null
}

# 0 when `axi status` output $2 is attributable to worktree $1: its head binds
# this worktree's code identity, OR no-mistakes' own branch_sync record binds
# the run to this worktree. Callers still require the run's branch to be this
# worktree's branch first, so neither arm can cross branches.
#
# bin/fm-teardown.sh deliberately keeps the narrower head-only rule: it ABORTS
# the run it attributes, and a mutating action stays on the evidence that needs
# no second record to be fresh. A read-only current-state report can accept the
# broader binding.
fm_nm_status_matches_worktree() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 run_head
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  fm_nm_head_matches_worktree "$wt" "$run_head" && return 0
  fm_nm_status_binds_worktree "$wt" "$out"
}
