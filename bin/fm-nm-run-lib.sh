#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption defined below. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Name of the tool this host can bound a subprocess with, or non-zero when it
# has none. ONE owner for that detection: fm_nm_run_bounded below uses it to
# pick how to run, and a caller that must tell "the call failed" apart from
# "this host cannot make a bounded call at all" - which fm_nm_run_bounded
# reports identically, as a bare exit 1 - asks here FIRST rather than
# re-deriving the same three probes and drifting from them.
fm_nm_bounded_tool() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  elif command -v perl >/dev/null 2>&1; then printf 'perl'
  else return 1
  fi
}

# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout
  shift 2
  have_timeout=$(fm_nm_bounded_tool) || have_timeout=none
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
# fm_nm_run_is_pipeline_owned_active below carries the one exemption: a live
# run whose pipeline currently owns the branch binds without head equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# Text of top-level TOON block $2 (e.g. branch_sync) in captured `axi status`
# output $1: the block's own children only, header dropped and the block's own
# indentation stripped so its direct children read as top-level - letting a
# caller re-scope into one of THOSE children by calling this again on the
# result (fm_nm_branch_sync_next_action_code does exactly that for
# branch_sync's next_action: child, below).
#
# sed ranges are inclusive of their end address, so the next top-level key -
# the line that TERMINATES the block - is part of the matched range and must be
# dropped here, at the source. Leaving it in would put a key from OUTSIDE the
# block into the block text every fm_nm_toon_field search below then scans,
# which is a false match on the block's own key name (`branch_sync:` followed
# by a top-level `state:` would answer fm_nm_branch_sync_state). Dropping it
# here rather than re-tightening fm_nm_toon_field's indentation requirement
# keeps fm_nm_toon_field usable on already-dedented recursive input, which the
# next_action lookup below relies on.
fm_nm_toon_block() {  # <toon-output> <block-key>
  printf '%s\n' "$1" | sed -n "
    /^[[:space:]]*$2:[[:space:]]*\$/,/^[^[:space:]][^:]*:/{
      /^[[:space:]]*$2:[[:space:]]*\$/d
      /^[^[:space:]][^:]*:/d
      s/^  //
      p
    }"
}

# First scalar value of key $2 anywhere in already-scoped TOON block text $1
# (typically fm_nm_toon_block's output). Safe only when no nested sub-block
# still present in that scope reuses the same key ahead of the one intended;
# each caller below names that invariant for its own key.
fm_nm_toon_field() {  # <block-text> <field-key>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  fm_nm_toon_field "$(fm_nm_toon_block "$1" branch_sync)" state
}

# branch_sync.next_action.code from captured `axi status` TOON $1.
# `code:` is NOT unique to next_action within branch_sync in general the way
# `state:` is unique to fm_nm_branch_sync_state's search above - a future
# no-mistakes release could add another code-bearing branch_sync sub-block
# ordered before next_action, which would silently mismatch a `state:`-style
# any-depth search. So this scopes twice instead: first to the branch_sync
# block, then to its next_action: child specifically, and only then looks for
# code: - anchored to the one sub-block that actually carries it today.
# `recover_custody` means the run left pipeline-committed work that never
# reached this worktree's branch (a fix round the daemon committed in its own
# gate-repo clone before the run went terminal) - `no-mistakes axi sync
# --recover` is the only way to land it. fm-teardown.sh's Fix 1 uses this to
# refuse discarding that work instead of orphaning it under a removed worktree.
fm_nm_branch_sync_next_action_code() {  # <toon-output>
  local branch_sync
  branch_sync=$(fm_nm_toon_block "$1" branch_sync)
  fm_nm_toon_field "$(fm_nm_toon_block "$branch_sync" next_action)" code
}

# branch_sync.local.head from captured `axi status` TOON $1: the daemon's own
# reading of the head this branch is at in the CREW's checkout, as opposed to
# the run's `head:` (the run's lane tip, which for a pipeline-owned run is
# routinely a gate-repo commit that never reached the worktree). Scoped twice
# for the same reason next_action.code is: `head:` is not unique to the local:
# sub-block within branch_sync (pipeline: carries current_head, and a future
# release could add another head-bearing sibling ordered ahead of local:).
fm_nm_branch_sync_local_head() {  # <toon-output>
  local branch_sync
  branch_sync=$(fm_nm_toon_block "$1" branch_sync)
  fm_nm_toon_field "$(fm_nm_toon_block "$branch_sync" local)" head
}

# branch_sync.pipeline.current_head from captured `axi status` TOON $1: the
# commit the PIPELINE currently holds for this branch in its own gate-repo
# clone. When that commit is not reachable from the crew worktree's HEAD, the
# pipeline is holding work the worktree has never seen - the unlanded fix-round
# commit fm-teardown.sh refuses to strand. Scoped twice, as above.
fm_nm_branch_sync_pipeline_current_head() {  # <toon-output>
  local branch_sync
  branch_sync=$(fm_nm_toon_block "$1" branch_sync)
  fm_nm_toon_field "$(fm_nm_toon_block "$branch_sync" pipeline)" current_head
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}
