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

# --- active-step progress evidence ------------------------------------------
#
# The supervisor's wedge detector has three liveness inputs that a crew parked on
# a validation run defeats all three of: its pane renders nothing (the pipeline,
# not the crew, is taking the turns), its run record says `running` for as long as
# the run lasts however stalled it is, and the pipeline commits its fix rounds in
# its own checkout, so the task worktree is never written. The evidence that does
# separate a progressing run from a stalled one is the run's own ACTIVE STEP: its
# log grows and its agent process burns CPU. The primitives below measure exactly
# that, and fm-classify-lib.sh's crew_run_step_advanced turns two measurements
# into the supervisor's verdict.
#
# Data rows of the `active_steps[N]{...}:` table in captured `axi status` TOON $1,
# which the pipeline emits only while a step is actually running or fixing - so an
# empty result is itself the fact that no step is executing. Column order is
# deliberately not assumed: the header's own indentation bounds the block, and
# fm_nm_active_step_field below resolves names to positions.
fm_nm_active_steps_rows() {  # <toon-output>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*active_steps\[[0-9]+\]\{/ { hdr = index($0, "active_steps"); inblock = 1; next }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { inblock = 0; next }
      match($0, /[^ \t]/)
      if (RSTART <= hdr) { inblock = 0; next }
      print
    }
  '
}

# Value of column <2> in the FIRST active-step row of captured `axi status` TOON
# $1, resolved through that table's own `{...}` header names rather than a fixed
# position, so a column added or reordered upstream cannot silently shift the
# reading. Values are comma-separated with TOON double quoting, so a quoted value
# may itself contain a comma; the split honors the quotes. Empty when the table,
# the column, or the row is absent - every caller treats that as no evidence.
fm_nm_active_step_field() {  # <toon-output> <column>
  printf '%s\n' "$1" | awk -v want="$2" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function split_toon(line, arr,   n, i, c, cur, inq) {
      n = 0; cur = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { inq = !inq; continue }
        if (c == "," && !inq) { arr[++n] = trim(cur); cur = ""; continue }
        cur = cur c
      }
      arr[++n] = trim(cur)
      return n
    }
    !col && match($0, /active_steps\[[0-9]+\]\{[^}]*\}/) {
      hdr = index($0, "active_steps")
      names = substr($0, RSTART, RLENGTH)
      sub(/^[^{]*\{/, "", names); sub(/\}$/, "", names)
      n = split_toon(names, name_at)
      for (i = 1; i <= n; i++) if (name_at[i] == want) col = i
      inblock = 1
      next
    }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) exit
      match($0, /[^ \t]/)
      if (RSTART <= hdr) exit
      if (!col) exit
      split_toon($0, value_at)
      print value_at[col]
      exit
    }
  '
}

# Whole seconds of CPU time process $1 has consumed, or nothing when the pid is
# absent, unreadable, or not a pid at all. The caller must pass a pid the RUN
# RECORD names, never one found by walking a pane's process tree: measured
# 2026-09-06 while diagnosing this very defect, a probe aimed at a pane's own
# child read 00:00:00 for a worker that was healthy and burning CPU further down
# the tree, and a measurement pointed at the wrong process answers confidently and
# wrongly instead of erroring.
# `ps -o time=` is the portable spelling
# and renders [[DD-]HH:]MM:SS with an optional fractional part on some platforms,
# so the parse folds every leading component and truncates the fraction rather
# than assuming one shape. A crew's step agent that is genuinely working advances
# this even across a gap between step-log writes, which is the whole reason it is
# read alongside the log.
fm_nm_pid_cpu_seconds() {  # <pid>
  local pid=$1 raw
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  raw=$(ps -o time= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | awk '
    { days = 0; rest = $0
      if (index(rest, "-")) { days = substr(rest, 1, index(rest, "-") - 1) + 0
                              rest = substr(rest, index(rest, "-") + 1) }
      n = split(rest, part, ":")
      total = 0
      for (i = 1; i <= n; i++) { v = part[i]; sub(/\..*$/, "", v); total = total * 60 + v + 0 }
      print days * 86400 + total }'
}

# One measurement of worktree $1's current validation run, printed as a single
# tab-separated record:
#
#   <run-id>\t<step>\t<step-log-bytes>\t<agent-pid>\t<agent-cpu-seconds>
#
# Every field is something that only moves when work happens. The step's own
# `active_for` is deliberately NOT among them: an elapsed-time counter advances
# whether or not anything is running, so a sample containing one could never read
# as stalled. The pid comes from the run record's `agent_pid`, which is the whole
# reason the CPU reading can be trusted (see fm_nm_pid_cpu_seconds).
#
# Prints NOTHING - and the caller reads that as no evidence, never as a stall -
# when no run is attributed to the branch, when the run carries no active step,
# or when either bounded call fails. The step is resolved from the run record on
# every measurement rather than pinned once, because a step that FINISHES leaves
# its log permanently flat and its agent gone while the run advances happily to
# the next step; a checker pinned to one step's log would report that healthy run
# as wedged forever. The run id is pinned across the two calls so the log read
# cannot land on a different run than the one just measured.
# The answered run must be THIS worktree's own: under concurrent load `axi status`
# routinely answers a different branch's run, and measuring that one would let one
# crew's progress defer another crew's wedge escalation. Branch equality is the
# right strength here - the strict head rule fm_nm_head_matches_worktree applies
# would reject exactly the pipeline-owned fix round whose head this copy never
# fetched, and a stale run on a reused branch cannot answer anyway, because the
# active_steps table exists only while a step is really executing.
# Two bounded no-mistakes calls: callers must reach this once per idle window,
# never per poll.
fm_nm_step_progress_probe() {  # <worktree> <timeout_secs>
  local wt=$1 timeout_secs=$2 status_out logs_out run_id step bytes pid cpu branch run_branch
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=''
  [ -n "$branch" ] || return 1
  status_out=$(fm_nm_run_checked "$wt" "$timeout_secs" axi status) || return 1
  [ -n "$status_out" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$status_out" branch)")
  [ "$run_branch" = "$branch" ] || return 1
  step=$(fm_nm_strip_quotes "$(fm_nm_active_step_field "$status_out" step)")
  [ -n "$step" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$status_out" id)")
  pid=$(fm_nm_strip_quotes "$(fm_nm_active_step_field "$status_out" agent_pid)")
  case "$pid" in *[!0-9]*) pid='' ;; esac
  cpu=$(fm_nm_pid_cpu_seconds "$pid" 2>/dev/null || true)
  if [ -n "$run_id" ]; then
    logs_out=$(fm_nm_run_checked "$wt" "$timeout_secs" axi logs --run "$run_id" --step "$step" --full) || return 1
  else
    logs_out=$(fm_nm_run_checked "$wt" "$timeout_secs" axi logs --step "$step" --full) || return 1
  fi
  bytes=$(printf '%s' "$logs_out" | wc -c | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$run_id" "$step" "$bytes" "$pid" "${cpu:-}"
}
