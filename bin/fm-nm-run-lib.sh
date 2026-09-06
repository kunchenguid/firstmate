#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Both bind a run
# by strict branch-and-head identity first, and both then recognize a provable
# pipeline-owned continuation through fm_nm_runs_status_for_worktree below:
# crew-state for an ACTIVE run, so a fix round never reads as an older failed
# run, and teardown for a run PARKED at a gate, so cleanup concludes it
# instead of orphaning it. Both then apply the ONE run-ownership rule at the
# end of this file (fm_nm_binding_is_declined for the stale-binding decline both
# make at their by-id refetch, then fm_nm_run_owned_by_task and
# fm_nm_branch_credit_owned_by_task), which separates concurrent crews whose
# worktrees sit on one branch through the run binding each crew records with
# bin/fm-run-bind.sh. Getting this wrong in either direction is unsafe: a false
# negative hides a genuinely parked run, and a false positive lets teardown act
# on a run it does not own.
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

# Full commit sha for sha-ish $2 as seen from worktree $1's own object store;
# empty when the object is absent or ambiguous. Read-only: never fetches,
# never moves refs or custody.
fm_nm_resolve_commit() {  # <worktree> <sha-ish>
  git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null || true
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# A run head whose object this copy does not have cannot be proven here and is
# rejected; fm_nm_runs_status_for_worktree below owns the one ledger-anchored
# recognition for that case, and fm_nm_run_is_pipeline_owned_active below
# carries the custody exemption: a live run whose pipeline currently owns the
# branch binds without head equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(fm_nm_resolve_commit "$wt" "$run_head")
  [ -n "$run_full" ] || return 1
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

# The custody exemption to the head rule above: while the pipeline OWNS the
# branch (branch_sync.state=pipeline_owned), the daemon's own branch
# attribution IS the attribution for an ACTIVE run, and
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

# ONE owner for attribution from the pipeline's own runs ledger, replacing a
# per-row scan-and-skip. The ledger is the real top-level `no-mistakes runs
# --limit N` listing (plain text, no run id, no quoting, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]"; the `axi` surface has no
# runs-listing subcommand - verified against the installed CLI). Prints the
# status word of the branch's CURRENT run row, or nothing when the ledger
# cannot prove attribution. When optional expected head $4 is supplied, its
# abbreviated commit identity must match the newest row. The branch's NEWEST
# row alone decides; older rows are history and never answer for the present:
#   - newest row's head resolves and matches the worktree (fm_nm_head_matches_worktree):
#     its status word
#   - newest row's head resolves but does not match: nothing (a newer run that
#     is not this worktree's makes every older row stale history)
#   - newest row's head does not resolve in this copy (the pipeline committed
#     its fix round in its own checkout and the task copy never fetched it):
#     recognized ONLY as a provable pipeline-owned continuation of the
#     submitted head, which requires ALL of: the row is ACTIVE (status
#     running), and the immediately older row for the SAME branch resolves to
#     EXACTLY the worktree HEAD. The pipeline's own ledger then proves an
#     unbroken run sequence from a run that ended at the submitted head to an
#     active run on the same branch - the anchored active row's status word is
#     printed. Anything else (no anchor row, an anchor that is merely an
#     ancestor, a terminal unresolvable row) prints nothing, so branch-name
#     coincidence, arbitrary remote state, and other tasks' runs never match.
# Read-only: git reads resolve objects in place; custody never changes.
fm_nm_runs_status_for_worktree() {  # <worktree> <branch> <runs-list-output> [expected-head]
  local wt=$1 branch=$2 list=$3 expected_head=${4:-}
  local local_full row st br sha day clock pr extra year_num month_num day_num max_day pending_st=''
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 0
  [ -n "$list" ] || return 0
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    IFS=$' \t' read -r st br sha day clock pr extra <<< "$row"
    [ -n "$st" ] && [ -n "$br" ] && [ -n "$sha" ] && [ -n "$day" ] && [ -n "$clock" ] || return 0
    [ -z "$extra" ] || return 0
    case "$st" in *[!a-z_-]*|'') return 0 ;; esac
    case "$br" in *[!A-Za-z0-9._/-]*|'') return 0 ;; esac
    case "$sha" in *[!A-Fa-f0-9]*|'') return 0 ;; esac
    case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 0 ;; esac
    case "$clock" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) return 0 ;; esac
    case "$pr" in ''|https://*) ;; *) return 0 ;; esac
    [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || return 0
    year_num=$((10#${day%%-*}))
    month_num=${day#*-}; month_num=${month_num%%-*}; month_num=$((10#$month_num))
    day_num=$((10#${day##*-}))
    [ "$year_num" -gt 0 ] && [ "$month_num" -ge 1 ] && [ "$month_num" -le 12 ] || return 0
    case "$month_num" in
      1|3|5|7|8|10|12) max_day=31 ;;
      4|6|9|11) max_day=30 ;;
      2)
        if (( year_num % 400 == 0 || (year_num % 4 == 0 && year_num % 100 != 0) )); then
          max_day=29
        else
          max_day=28
        fi
        ;;
    esac
    [ "$day_num" -ge 1 ] && [ "$day_num" -le "$max_day" ] || return 0
    [ "$br" = "$branch" ] || continue
    if [ -n "$pending_st" ]; then
      # This is the row immediately older than the active unresolvable row:
      # the only admissible anchor, and only exact head equality proves the
      # worktree still sits at the submitted head.
      if [ "$(fm_nm_resolve_commit "$wt" "$sha")" = "$local_full" ]; then
        printf '%s' "$pending_st"
      fi
      return 0
    fi
    if [ -n "$expected_head" ]; then
      case "$expected_head" in *[!A-Fa-f0-9]*|'') return 0 ;; esac
      [ "${#expected_head}" -ge 7 ] && [ "${#expected_head}" -le 40 ] || return 0
      case "$expected_head" in
        "$sha"*) ;;
        *) case "$sha" in "$expected_head"*) ;; *) return 0 ;; esac ;;
      esac
    fi
    if [ -n "$(fm_nm_resolve_commit "$wt" "$sha")" ]; then
      if fm_nm_head_matches_worktree "$wt" "$sha"; then
        printf '%s' "$st"
      fi
      return 0
    fi
    [ "$st" = running ] || return 0
    pending_st=$st
  done <<< "$list"
  return 0
}

# --- run ownership across concurrent crews on ONE branch ---------------------
#
# Branch plus head identity cannot tell apart concurrent crews whose worktrees
# sit on one long-lived feature branch: no-mistakes exposes nothing that names
# the worktree a run was invoked from (`axi status` is repo-scoped and answers
# the identical run from any worktree of the repo, the `runs` listing carries no
# such column, and the private runs.worktree_dir record holds the pipeline's own
# internal checkout - verified 2026-09-04 against two live worktrees of one
# branch on v1.57.0). The one unambiguous identifier is the run id, and only
# the crew that started a run knows which id is its own, so it records it as
# `nm_run=<run-id>` in its task record through bin/fm-run-bind.sh. These
# predicates are the ONE ownership rule both consumers apply on top of the
# branch-and-head rules above: fm-crew-state.sh before crediting a run as a
# crew's working proof, fm-teardown.sh before aborting a parked run. Every
# record read here is the home's own state/<id>.meta, and the only per-record
# lookup is one local `git symbolic-ref` read of a BOUND sibling's recorded
# worktree. No no-mistakes CLI call is ever issued for a sibling: crew-state
# runs on bin/fm-watch.sh's per-poll path and bin/fm-fleet-snapshot.sh runs it
# for every task, so a bounded CLI call per bound sibling would multiply to
# tasks x bound siblings x timeout per poll and stall supervision. The known
# limit this buys: a bound sibling whose worktree has since detached, moved to
# another branch, or been torn down is no longer seen as holding this branch,
# so it withholds nothing on the branch-level route (it still owns the run it
# bound on the id route, whatever its worktree does).

# The last value of key $2 in task record $1; empty when the record is absent
# or never wrote the key.
fm_nm_task_meta_value() {  # <meta-file> <key>
  local line value=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#"$2="} ;; esac
  done < "$1" 2>/dev/null || true
  printf '%s' "$value"
}

# The run binding of task record $1 (its last `nm_run=` key); empty when the
# record is absent or unbound.
fm_nm_task_bound_run() {  # <meta-file>
  fm_nm_task_meta_value "$1" nm_run
}

# The DECLINE rule for a stale binding, applied by BOTH consumers at the point
# where they refetch their own run by id, so the read path and the abort path
# never diverge about which answer a binding is worth. A crew that restarts
# validation and does not re-bind would otherwise be pinned to its own finished
# run: fm-crew-state.sh reports `state: failed - run cancelled` for a crew that
# is actively validating, and fm-teardown.sh finds no parked run of its own and
# removes the worktree while that crew's genuinely live run stays parked at a
# gate, orphaned - the exact outcome its "Fix 1" exists to prevent. So the
# binding is declined, and the caller falls through to the unbound path (the
# branch guess this whole contract exists to improve on, which is what makes a
# missed re-bind self-healing rather than a confident wrong answer), when ALL of:
#   - the bound run's own answer (TOON $1) reached a terminal outcome
#   - the repo's CURRENT run (TOON $2) is a DIFFERENT id
#   - that current run is on the crew's own branch $3
# An ACTIVE bound run always keeps precedence, so a genuinely running own run is
# never given up for a sibling's, and a current run on ANOTHER branch says
# nothing about this crew and never declines its binding. An empty or malformed
# bound answer reads as active here and is likewise never declined: a CLI that
# did not respond is not evidence that a binding is stale.
fm_nm_binding_is_declined() {  # <bound-run-toon> <current-run-toon> <crew-branch>
  local bound=$1 current=$2 branch=$3 bound_id current_id
  [ -n "$bound" ] && [ -n "$current" ] && [ -n "$branch" ] || return 1
  bound_id=$(fm_nm_strip_quotes "$(fm_nm_field "$bound" id)")
  current_id=$(fm_nm_strip_quotes "$(fm_nm_field "$current" id)")
  [ -n "$current_id" ] && [ "$current_id" != "$bound_id" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$current" branch)")" = "$branch" ] || return 1
  ! fm_nm_run_is_active "$bound"
}

# Prints the id of the task OTHER than $2 whose record in state dir $1 binds run
# id $3, and returns 0; returns 1 (printing nothing) when no other task binds it.
# Self is excluded by task id rather than by record path, because a supervisor
# may read this task's record through a captured copy (bin/fm-fleet-snapshot.sh)
# while the live record under $1 is the same task, not a rival claimant.
fm_nm_run_bound_by_other_task() {  # <state-dir> <task-id> <run-id>
  local state=$1 self=$2 run_id=$3 meta
  [ -n "$run_id" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "${meta##*/}" != "$self.meta" ] || continue
    if [ "$(fm_nm_task_bound_run "$meta")" = "$run_id" ]; then
      printf '%s' "${meta##*/}" | sed 's/\.meta$//'
      return 0
    fi
  done
  return 1
}

# Branch the recorded worktree of task record $1 currently sits on, read
# locally from its git ref; empty when the record names no worktree, the
# worktree is gone, or it is at detached HEAD.
fm_nm_task_worktree_branch() {  # <meta-file>
  local wt
  wt=$(fm_nm_task_meta_value "$1" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# Prints the id of a task OTHER than $2 whose record in state dir $1 binds a run
# AND whose recorded worktree currently sits on branch $3, and returns 0;
# returns 1 (printing nothing) when no bound sibling holds the branch. Only
# records carrying an `nm_run=` binding are examined, and when both this task's
# `project=` root ($4, optional) and the sibling's are recorded, a sibling of
# another project is skipped: a run of another repo can never be this branch's.
# The sibling's branch is one local git ref read, never a CLI call (see the
# section header for the cost argument and the detached-worktree limit).
fm_nm_branch_bound_sibling() {  # <state-dir> <task-id> <branch> [project]
  local state=$1 self=$2 branch=$3 project=${4:-} meta sibling_project
  [ -n "$branch" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "${meta##*/}" != "$self.meta" ] || continue
    [ -n "$(fm_nm_task_bound_run "$meta")" ] || continue
    if [ -n "$project" ]; then
      sibling_project=$(fm_nm_task_meta_value "$meta" project)
      [ -z "$sibling_project" ] || [ "$sibling_project" = "$project" ] || continue
    fi
    if [ "$(fm_nm_task_worktree_branch "$meta")" = "$branch" ]; then
      printf '%s' "${meta##*/}" | sed 's/\.meta$//'
      return 0
    fi
  done
  return 1
}

# The ownership rule for a run named by id. 0 if run $4 may be credited to, or
# acted on for, task $2 whose own binding is $3 (empty when unbound), given the
# home's records in state dir $1:
#   - bound, ids equal: ours, whatever the branch says
#   - bound, ids differ: not ours - the run is someone else's
#   - unbound, another task binds this id: not ours - it is spoken for
#   - unbound, nobody binds this id: ours by the legacy branch rule, so a home
#     whose crews predate bindings regresses in no way
fm_nm_run_owned_by_task() {  # <state-dir> <task-id> <own-binding> <run-id>
  local state=$1 self=$2 own=$3 run_id=$4
  if [ -n "$own" ]; then
    [ -n "$run_id" ] && [ "$run_id" = "$own" ]
    return
  fi
  ! fm_nm_run_bound_by_other_task "$state" "$self" "$run_id" >/dev/null
}

# The ownership rule for branch-level credit, where no run id is available (the
# `runs` ledger carries none). 0 if task $2 with own binding $3 may take credit
# for whatever the ledger reports as branch $4's current run:
#   - bound: yes, but ONLY because a bound caller never reaches this rule with
#     an unidentified row. fm-crew-state.sh admits a bound crew to the ledger
#     solely to confirm its OWN run (fetched by id, on this branch) is the
#     branch's current row, matching that run's head against the row before
#     parsing the run; fm-teardown.sh has already passed the run through the id
#     rule above. A bound crew is never handed a row that is not its own run
#   - unbound, some other task binds a run and its worktree sits on this
#     branch: no - the branch's runs are spoken for, and branch credit would
#     hand the sibling's run to a crew that never started one. This holds even
#     when the sibling's binding is stale (its run already terminal): the
#     ledger cannot tell the branch's current row from that run, so credit is
#     withheld rather than guessed, and the cure is the owning crew binding
#   - unbound, no bound sibling holds the branch: the legacy branch rule
# $5 is fm_nm_branch_bound_sibling's optional project root for scoping.
fm_nm_branch_credit_owned_by_task() {  # <state-dir> <task-id> <own-binding> <branch> [project]
  local state=$1 self=$2 own=$3 branch=$4 project=${5:-}
  [ -z "$own" ] || return 0
  ! fm_nm_branch_bound_sibling "$state" "$self" "$branch" "$project" >/dev/null
}
