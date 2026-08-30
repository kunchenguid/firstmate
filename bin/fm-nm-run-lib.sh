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
# This rule governs the BRANCH READ (`axi status`), where a run is bound to
# this worktree by code identity; fm_nm_run_is_pipeline_owned_active below
# carries its one exemption, a live run whose pipeline currently owns the
# branch. The corroboration listing is a different question and does not use
# this rule at all: a row that says a run on this branch is still in flight is
# a run in flight whatever head it carries, so it binds by branch alone.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
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

# The bounded corroboration window read from `no-mistakes runs`. The listing is
# repo-wide and has neither pagination nor an end-of-list marker, so it can add
# a run this branch owns but can never be asked to prove the absence of one.
# FM_CREW_STATE_RUNS_LIMIT is the superseded name for the same window.
fm_nm_runs_limit() {
  local n=${FM_NM_RUNS_LIMIT:-${FM_CREW_STATE_RUNS_LIMIT:-200}}
  case "$n" in ''|*[!0-9]*|0) n=200 ;; esac
  printf '%s' "$n"
}

# `no-mistakes` answers a repository it holds no registration for with a
# not-initialized error and no rows at all. A repository with no registration
# owns no run, so that is an answer, not a failure to answer - the same
# reasoning the branchless worktree rests on. firstmate supports whole project
# modes (direct-PR, local-only) that never run `no-mistakes init`.
fm_nm_says_unregistered() {  # <response-text>...
  local response text
  for response in "$@"; do
    text=$(printf '%s' "$response" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case "$text" in
      *"repo not initialized"*|*"repo not initialised"*) return 0 ;;
    esac
  done
  return 1
}

# Bounded `no-mistakes` call in $1 whose stdout and stderr are written into the
# variables named by $2 and $3 rather than stderr being discarded, so a caller
# can inspect the CLI's complete response when it explains a failure on either
# stream. Both variables are assigned in the caller's scope - the call must NOT
# be wrapped in a command
# substitution - and the CLI's exit status is returned, or 1 when no scratch
# file could be opened for the error stream.
fm_nm_run_capturing_stderr() {  # <dir> <stdout-var> <stderr-var> <timeout_secs> <args...>
  local dir=$1 outvar=$2 errvar=$3 timeout=$4 err='' rc=0 out=''
  shift 4
  printf -v "$outvar" '%s' ''
  printf -v "$errvar" '%s' ''
  if command -v mktemp >/dev/null 2>&1; then
    err=$(mktemp "${TMPDIR:-/tmp}/fm-nm-err.XXXXXX" 2>/dev/null) || err=
  fi
  if [ -z "$err" ]; then
    err="${TMPDIR:-/tmp}/fm-nm-err.$$.${RANDOM}${RANDOM}"
    ( set -o noclobber; : > "$err" ) 2>/dev/null || return 1
  fi
  if out=$(fm_nm_run_bounded "$dir" "$timeout" "$@" 2>"$err"); then rc=0; else rc=$?; fi
  printf -v "$outvar" '%s' "$out"
  printf -v "$errvar" '%s' "$(<"$err")"
  rm -f "$err" 2>/dev/null || :
  return "$rc"
}

# shellcheck disable=SC2034 # FM_NM_BRANCH_RUN_* is this function's documented output tuple.
# `fm_nm_branch_run_verdict` is the one authoritative answer to whether a
# branch owns a live no-mistakes run. It writes `active`, `quiet`, or `unknown`
# to FM_NM_BRANCH_RUN_VERDICT, with one diagnostic reason in
# FM_NM_BRANCH_RUN_REASON when the answer is unknown.
#
# THE QUESTION IS ALWAYS "DOES THIS BRANCH HAVE AN ACTIVE RUN?", AND THE BRANCH
# READ ANSWERS IT. `no-mistakes axi status` reports the repository's ACTIVE run
# and only falls back to the most recent one when nothing is in flight, so a
# successful call that places no non-terminal run on this branch is an answer:
# this branch is quiet, whether the CLI named another branch's run or had
# nothing to report at all. Only a branch read that could not be made - the CLI
# failed or timed out, named an active run without a placeable branch identity,
# or named a live run on this branch whose head cannot be placed against this
# worktree - leaves the question open, and an open question refuses the caller
# that needs it proven.
#
# The repo-wide `runs` listing is CORROBORATION ONLY. A non-terminal row for
# this branch is a second way to establish `active` (the listing's status column
# is each run's current status, so it catches a run a stale `axi status` answer
# missed), but its absence proves nothing: a full window, an unreadable row, a
# failed call, an unregistered repo or an absent CLI must never turn a readable
# quiet branch read into a refusal. That is why widening FM_NM_RUNS_LIMIT is a
# reporting nicety rather than a safety setting.
#
# The optional display and TOON fields are reporting projections, never a
# second safety decision, and they are assigned in exactly one place below.
# Terminal detail is projected only when the branch read agrees in state and
# head with the newest same-branch terminal listing row; older terminal rows
# can never corroborate it. Active evidence remains authoritative without
# projecting details, and a direct active answer skips the optional listing
# entirely.
fm_nm_branch_run_verdict() {  # <worktree> <branch> <timeout_secs> [limit]
  local wt=$1 branch=$2 timeout=$3 limit=${4:-}
  local status_out='' status_rc status_stderr='' status_body='' direct_status=''
  local run_branch_raw='' run_branch='' run_head=''
  local branch_state=unknown branch_reason='' active_id='' terminal_toon=''
  local terminal_status='' terminal_outcome='' terminal_head='' terminal_corroborated=0
  local inventory row st rest br sha render_locked=0
  local listing_live='' direct_full='' listing_full=''
  FM_NM_BRANCH_RUN_VERDICT=unknown
  FM_NM_BRANCH_RUN_REASON=
  FM_NM_BRANCH_RUN_ID=
  FM_NM_BRANCH_RUN_DISPLAY=
  FM_NM_BRANCH_RUN_TOON=
  case "$limit" in ''|*[!0-9]*|0) limit=$(fm_nm_runs_limit) ;; esac
  [ -d "$wt" ] || {
    FM_NM_BRANCH_RUN_REASON="worktree '$wt' is not readable, so whether branch '$branch' has a run in flight could not be read"
    return 0
  }
  [ -n "$branch" ] || {
    FM_NM_BRANCH_RUN_VERDICT=quiet
    return 0
  }
  command -v no-mistakes >/dev/null 2>&1 || {
    FM_NM_BRANCH_RUN_VERDICT=quiet
    return 0
  }
  if fm_nm_run_capturing_stderr "$wt" status_out status_stderr "$timeout" axi status; then status_rc=0; else status_rc=$?; fi
  if [ "$status_rc" = 0 ]; then
    branch_state=quiet
    status_body=$(fm_nm_trim "$status_out")
    if [ -n "$status_body" ]; then
      direct_status=$(fm_nm_strip_quotes "$(fm_nm_field "$status_out" status)")
      run_branch_raw=$(fm_nm_trim "$(fm_nm_field "$status_out" branch)")
      run_branch=$(fm_nm_strip_quotes "$run_branch_raw")
      run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$status_out" head)")
      if [ -z "$direct_status" ]; then
        branch_state=unknown
        branch_reason="'no-mistakes axi status' returned a non-empty result without a readable run status for branch $branch"
      elif fm_nm_run_is_active "$status_out"; then
        case "$run_branch_raw" in
          \"*\") ;;
          *\"*) run_branch= ;;
        esac
        if [ -z "$run_branch" ] \
          || ! git check-ref-format --branch "$run_branch" >/dev/null 2>&1; then
          branch_state=unknown
          branch_reason="the active run 'no-mistakes axi status' reports has no placeable branch identity, so whether it belongs to branch $branch cannot be proved"
        elif [ "$run_branch" = "$branch" ]; then
          if fm_nm_head_matches_worktree "$wt" "$run_head" \
            || fm_nm_run_is_pipeline_owned_active "$status_out"; then
            branch_state=active
            active_id=$(fm_nm_strip_quotes "$(fm_nm_field "$status_out" id)")
          else
            branch_state=unknown
            branch_reason="the run 'no-mistakes axi status' reports on branch $branch (head ${run_head:-unknown}) cannot be placed against this worktree's HEAD"
          fi
        fi
      elif [ "$run_branch" = "$branch" ] \
        && fm_nm_head_matches_worktree "$wt" "$run_head"; then
        terminal_toon=$status_out
        terminal_status=$(fm_nm_strip_quotes "$(fm_nm_field "$status_out" status)")
        terminal_outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$status_out" outcome)")
        case "$terminal_outcome" in
          failed) terminal_status=failed ;;
          cancelled) terminal_status=cancelled ;;
          passed|checks-passed) terminal_status=completed ;;
        esac
        terminal_head=$run_head
      fi
    fi
  elif [ "$status_rc" != 0 ] \
    && fm_nm_says_unregistered "$status_out" "$status_stderr"; then
    branch_state=quiet
  else
    branch_reason="'no-mistakes axi status' could not answer whether branch $branch has a run in flight"
  fi
  if [ "$branch_state" != active ] \
    && inventory=$(fm_nm_run_checked "$wt" "$timeout" runs --limit "$limit"); then
    while IFS= read -r row; do
      row=$(fm_nm_trim "$row")
      [ -n "$row" ] || continue
      case "$row" in *" "*) ;; *) continue ;; esac
      st=${row%% *}
      rest=$(fm_nm_trim "${row#* }")
      [ -n "$rest" ] || continue
      br=${rest%% *}
      rest=$(fm_nm_trim "${rest#* }")
      sha=${rest%% *}
      { [ -n "$br" ] && [ -n "$sha" ]; } || continue
      [ "$br" = "$branch" ] || continue
      case "$st" in
        completed|failed|cancelled)
          if [ "$render_locked" = 0 ]; then
            render_locked=1
            if fm_nm_head_matches_worktree "$wt" "$sha" \
              && [ -n "$terminal_toon" ] \
              && [ "$st" = "$terminal_status" ]; then
              direct_full=$(git -C "$wt" rev-parse --verify "${terminal_head}^{commit}" 2>/dev/null || true)
              listing_full=$(git -C "$wt" rev-parse --verify "${sha}^{commit}" 2>/dev/null || true)
              if [ -n "$direct_full" ] && [ "$direct_full" = "$listing_full" ]; then
                terminal_corroborated=1
              fi
            fi
          fi
          ;;
        *)
          [ -n "$listing_live" ] || listing_live="$st $sha"
          ;;
      esac
    done <<< "$inventory"
  fi
  if [ "$branch_state" = active ]; then
    FM_NM_BRANCH_RUN_VERDICT=active
    FM_NM_BRANCH_RUN_ID=$active_id
  elif [ -n "$listing_live" ]; then
    FM_NM_BRANCH_RUN_VERDICT=active
  elif [ "$branch_state" = quiet ]; then
    FM_NM_BRANCH_RUN_VERDICT=quiet
  else
    FM_NM_BRANCH_RUN_REASON=$branch_reason
  fi
  if [ "$FM_NM_BRANCH_RUN_VERDICT" = quiet ] \
    && [ "$terminal_corroborated" = 1 ]; then
    FM_NM_BRANCH_RUN_TOON=$terminal_toon
  fi
}
