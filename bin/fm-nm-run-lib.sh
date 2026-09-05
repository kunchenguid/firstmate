#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and by the two paths
# that remove the worker a parked gate is waiting on - fm-teardown.sh (see its
# "Fix 1" header comment) and fm-control.sh's relaunch, which both conclude the
# run through conclude_task_no_mistakes_run below before they signal anything
# in the copy. They bind a run
# by strict branch-and-head identity first, and they then recognize a provable
# pipeline-owned continuation through fm_nm_runs_status_for_worktree below:
# crew-state for an ACTIVE run, so a fix round never reads as an older failed
# run, and teardown for a run PARKED at a gate, so cleanup concludes it
# instead of orphaning it. Getting this wrong in either
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

# Fix 1 (see bin/fm-teardown.sh's script header): does the active-or-most-recent
# no-mistakes run in worktree $1 belong to THIS task, and is it parked at a gate
# awaiting an agent that is about to be removed? Prints nothing; returns 0 only
# on a genuine match so the caller knows it is safe to abort - never a guess.
# Identity binds through the strict object-local head rule, with the shared
# ledger-anchored continuation rule above as the only recognition for a head
# this copy cannot resolve at all.
NM_TEARDOWN_TIMEOUT=${FM_TEARDOWN_NM_TIMEOUT:-10}
case "$NM_TEARDOWN_TIMEOUT" in ''|*[!0-9]*) NM_TEARDOWN_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the parked-run
# continuation proof may scan, mirroring bin/fm-crew-state.sh's limit posture
# (generous: rows of other branches interleave freely in the real ledger).
NM_TEARDOWN_RUNS_LIMIT=${FM_TEARDOWN_NM_RUNS_LIMIT:-200}
case "$NM_TEARDOWN_RUNS_LIMIT" in ''|*[!0-9]*) NM_TEARDOWN_RUNS_LIMIT=200 ;; esac
TASK_RUN_ID=
task_status_is_own_parked_run() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 branch run_id run_branch run_head status outcome awaiting has_gate ledger
  TASK_RUN_ID=
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$run_id" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  [ -n "$run_branch" ] && [ "$run_branch" = "$branch" ] || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  [ -z "$outcome" ] || return 1
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  [ -n "$status" ] || return 1
  case "$status" in
    completed|failed|cancelled|passed|checks-passed|running|fixing|ci) return 1 ;;
  esac
  if ! fm_nm_head_matches_worktree "$wt" "$run_head"; then
    # The strict object-local rule rejected this run head. That rejection is
    # final when the head object resolves in this copy (diverged or rewritten
    # tips are genuine mismatches), but when the object is absent entirely -
    # the pipeline committed its fix round in its own repo and this copy
    # never fetched it - the ONE shared runs-ledger rule in
    # bin/fm-nm-run-lib.sh owns the only remaining recognition, and it prints
    # nothing for any ledger shape it cannot prove, so the run stays
    # untouched unless the ledger proves this exact continuation. Cleanup
    # consumes only an explicitly active (`running`) proved word: a terminal
    # newest row is finished history, never this parked run's abort
    # authorization (the read path classifies the same owner's answer; the
    # abort here must never fire for a run that already ended).
    [ -n "$run_head" ] || return 1
    [ -z "$(fm_nm_resolve_commit "$wt" "$run_head")" ] || return 1
    ledger=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" runs --limit "$NM_TEARDOWN_RUNS_LIMIT")
    [ "$(fm_nm_runs_status_for_worktree "$wt" "$branch" "$ledger" "$run_head")" = running ] || return 1
  fi
  awaiting=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  has_gate=$(printf '%s\n' "$out" | grep -Eq '^[[:space:]]*gate:[[:space:]]*' && echo 1 || echo 0)
  case "$status" in
    awaiting_approval|fix_review) TASK_RUN_ID=$run_id; return 0 ;;
  esac
  if [ -n "$awaiting" ] || [ "$has_gate" = 1 ]; then
    TASK_RUN_ID=$run_id
    return 0
  fi
  return 1
}

task_run_is_own_parked_run() {  # <worktree>
  local wt=$1 out
  # Accepted best-effort residual: query failures stay fail-open because making
  # no-mistakes availability a prerequisite would block ship tasks with no run.
  out=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" axi status)
  task_status_is_own_parked_run "$wt" "$out"
}

task_status_is_terminal_run() {  # <axi-status-output> <run-id>
  local out=$1 expected_id=$2 run_id outcome
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ "$run_id" = "$expected_id" ] || return 1
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    cancelled|failed|passed|checks-passed) return 0 ;;
  esac
  return 1
}

task_status_is_run_not_found() {  # <status-error> <run-id>
  local actual expected
  actual=$(fm_nm_trim "$1")
  expected=$(printf 'error: "run \\"%s\\" not found"' "$2")
  [ "$actual" = "$expected" ]
}

# Abort THIS task's own parked no-mistakes run before the worker that would
# have answered its gate is removed, so no run is left orphaned holding a
# fleet slot. Only KIND=ship drives a no-mistakes validation of its own
# worktree (scouts and secondmates never do, mirroring bin/fm-crew-state.sh);
# a run not attributed to this exact branch+head is left completely alone.
conclude_task_no_mistakes_run() {  # <worktree>
  local wt=$1 out run_id
  [ "$KIND" = ship ] || return 0
  [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  task_run_is_own_parked_run "$wt" || return 0
  run_id=$TASK_RUN_ID
  echo "no-mistakes run for $ID is parked at a gate; aborting before the worker is removed" >&2
  # Accepted best-effort residual: abort supports run-id targeting but no atomic
  # live-state condition; fully closing the resume race needs upstream compare-and-cancel.
  fm_nm_run_checked "$wt" "$NM_TEARDOWN_TIMEOUT" axi abort --run "$run_id" >/dev/null 2>&1 || true
  if out=$(fm_nm_run_bounded "$wt" "$NM_TEARDOWN_TIMEOUT" axi status --run "$run_id" 2>&1); then
    task_status_is_terminal_run "$out" "$run_id" && return 0
  elif task_status_is_run_not_found "$out" "$run_id"; then
    return 0
  fi
  echo "REFUSED: no-mistakes run for $ID is still parked after axi abort; confirm it stopped (no-mistakes axi status) or abort it manually (no-mistakes axi abort --run <id>) before retrying." >&2
  return 1
}
