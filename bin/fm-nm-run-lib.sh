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
#   - head that is not a resolvable object in this worktree: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
#
# The unresolvable-head rejection is deliberate and stays deliberate: an object
# this worktree cannot see is an ABSENCE of evidence, not evidence of ownership,
# and the same absence is produced both by a live pipeline whose fix commits are
# not local yet and by a branch whose old tip was rewritten away. Nothing in the
# object store separates those two, so this rule refuses both and ownership for
# the live case is established by fm_nm_run_owns_worktree_by_branch_sync below,
# from no-mistakes' own custody statement. Keeping this rule strict matters
# because fm-teardown.sh shares it, where a false positive lets teardown abort a
# run it does not own.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Lines of the TOON block named $3 nested at $2 spaces of indent inside output
# $1, excluding the block's own header line. The block ends at the first later
# non-blank line indented at or above that level. Nested paths are read by
# composing calls (branch_sync, then local within it), so a scalar lookup can be
# scoped to the block that owns it: `run:` and `branch_sync.local:` both carry a
# bare `head:`, and fm_nm_field alone would always answer with the first one.
fm_nm_block() {  # <toon-output> <indent> <key>
  printf '%s\n' "$1" | awk -v ind="$2" -v key="$3" '
    BEGIN { pad = ""; for (i = 0; i < ind + 0; i++) pad = pad " "; hdr = pad key ":" }
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    done { next }
    !inside { if (line == hdr) inside = 1; next }
    {
      if (line == "") { print; next }
      match($0, /^ */)
      if (RLENGTH <= ind + 0) { done = 1; inside = 0; next }
      print
    }
  '
}

# Scalar value of TOON key $2 belonging to the RUN OBJECT of `axi status` output
# $1, i.e. scoped to the top-level `run:` block when the output has one and read
# unscoped otherwise (older or flatter shapes that emit the run's fields at top
# level). Every read of a run field must go through this rather than fm_nm_field:
# `run:` and `branch_sync.local:` both carry a bare `head:`, and a plain
# fm_nm_field answers with whichever appears first, so a run object that simply
# omits a key would silently borrow the branch_sync value - and branch_sync.local
# describes this worktree by construction, which would turn an absent run head
# into a false identity match.
fm_nm_run_field() {  # <toon-output> <key>
  if printf '%s\n' "$1" | grep -q '^run:[[:space:]]*$'; then
    fm_nm_field "$(fm_nm_block "$1" 0 run)" "$2"
  else
    fm_nm_field "$1" "$2"
  fi
}

# 0 when `axi status` output $2 itself asserts that the run it reports currently
# holds custody of worktree $1's branch, independent of whether that run's head
# is a visible object here.
#
# Why this exists (traced live on a running pipeline, 2026-08-08, no-mistakes
# v1.45.4): while a run is in its pre_push phase, no-mistakes commits every
# gate fix round into its own gate repo under ~/.no-mistakes/repos/<id>.git, not
# into the crew worktree. The head it reports is therefore not an object in the
# crew worktree at all (`git cat-file -e <run head>` -> "Not a valid object name"),
# so fm_nm_head_matches_worktree above cannot bind by either of its tests, and a
# healthy running pipeline was read as unattributed. That is not a rare corner:
# it is the normal state of every no-mistakes run that has made a fix commit and
# not pushed yet.
#
# So ask no-mistakes rather than guess from the object store. `axi status` emits
# a branch_sync object only when the run it reports actually relates to the
# invoking worktree - verified by querying the same run from the repo's own main
# clone on `main`, which returned the run as informational display with no
# branch_sync block at all - and branch_sync.state names current custody from a
# fixed vocabulary (pipeline_owned, user_owned, target_changed, remote_missing,
# legacy_unbound, and the blocked_* variants). Every conjunct below is required,
# so the predicate stays a proof rather than a hint. Three of them carry the
# safety weight and each is pinned by its own case in
# tests/fm-crew-state.test.sh, verified by deleting the conjunct and watching
# exactly that case fail:
#   state == pipeline_owned            a live pipeline holds the branch right
#                                      now. A terminal, cancelled or abandoned
#                                      run cannot report this, so the rewritten
#                                      and stale-branch cases the head rule
#                                      exists to catch stay caught here too.
#   pipeline.run == run.id             the custody claim is about the run being
#                                      attributed, not a different one. The CLI
#                                      serves this block from a cache ("full
#                                      detail plus cached branch_sync when
#                                      relevant"), so a claim about some other
#                                      run is a real answer, not a hypothetical.
#   pipeline.submitted_head == HEAD    the run is validating exactly the commit
#                                      checked out here. This is the direct
#                                      replacement for the object-visibility
#                                      test: local work that advanced past
#                                      submission, or a rewritten tip, breaks
#                                      this equality and attribution is refused.
# The remaining two are fail-closed consistency checks on the cached block
# rather than independently load-bearing, and are kept deliberately: given the
# caller's branch-name precondition and the submitted_head equality above,
# nothing coherent can break them alone, so no test isolates them. They cost two
# string compares and reject an inconsistent or cross-repo cached answer instead
# of trusting it.
#   local.branch == worktree branch    the cached block describes this branch,
#   local.head == worktree HEAD        and this worktree's current checkout.
# The empty-block check is a cheap path, not a guard: an absent branch_sync
# leaves state empty, which the pipeline_owned test already rejects.
fm_nm_run_owns_worktree_by_branch_sync() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 sync_block state_field local_block pipeline_block
  local wt_branch wt_head run_id sync_branch sync_head pipeline_run submitted_head
  [ -n "$out" ] || return 1
  sync_block=$(fm_nm_block "$out" 0 branch_sync)
  [ -n "$sync_block" ] || return 1
  state_field=$(fm_nm_strip_quotes "$(fm_nm_field "$sync_block" state)")
  [ "$state_field" = pipeline_owned ] || return 1
  wt_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$wt_branch" ] || return 1
  wt_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  [ -n "$wt_head" ] || return 1
  local_block=$(fm_nm_block "$sync_block" 2 local)
  sync_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$local_block" branch)")
  [ "$sync_branch" = "$wt_branch" ] || return 1
  sync_head=$(fm_nm_strip_quotes "$(fm_nm_field "$local_block" head)")
  [ "$sync_head" = "$wt_head" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_run_field "$out" id)")
  [ -n "$run_id" ] || return 1
  pipeline_block=$(fm_nm_block "$sync_block" 2 pipeline)
  pipeline_run=$(fm_nm_strip_quotes "$(fm_nm_field "$pipeline_block" run)")
  [ "$pipeline_run" = "$run_id" ] || return 1
  submitted_head=$(fm_nm_strip_quotes "$(fm_nm_field "$pipeline_block" submitted_head)")
  [ "$submitted_head" = "$wt_head" ] || return 1
  return 0
}

# The ONE code-identity rule for a full `axi status` answer: does the run it
# reports belong to worktree $1? True when the reported head binds to this
# worktree's history, OR when no-mistakes' own branch_sync object proves current
# pipeline custody of this worktree's branch and head. The run's branch NAME
# match stays the caller's precondition, checked before this is consulted.
fm_nm_status_matches_worktree() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 run_head
  run_head=$(fm_nm_strip_quotes "$(fm_nm_run_field "$out" head)")
  fm_nm_head_matches_worktree "$wt" "$run_head" && return 0
  fm_nm_run_owns_worktree_by_branch_sync "$wt" "$out"
}
