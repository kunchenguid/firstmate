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
#
# This predicate binds one run at a time, and MORE THAN ONE recorded run can
# bind to the same worktree at once: a run that died at the worktree's exact
# commit still binds by the equal-commit rule while its live successor binds by
# the ancestor rule (observed 2026-08: a crashed validation daemon left a failed
# run at the worktree's own commit while the live run that replaced it validated
# a descendant commit on the same branch).
# When several runs bind, a LIVE run always outranks a terminal one, whichever
# match rule each one used, because a terminal run can be the corpse of a
# crashed attempt while the live one is what is actually validating this code.
# Within one liveness class the selecting caller's existing precedence is
# unchanged - for the runs ledger, fm_nm_runs_status_for_worktree's
# newest-row-decides rule below.
# fm_nm_run_status_class next classifies a recorded status word for that
# comparison, and a word it cannot classify keeps the caller's own precedence
# rather than being held back for a live row to displace.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(fm_nm_resolve_commit "$wt" "$run_head")
  [ -n "$run_full" ] || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Liveness class of a recorded run's status word, echoed as "terminal", "live",
# or "unknown", for the live-over-terminal selection rule above.
# The coarse `no-mistakes runs` ledger emits exactly these four status words; an
# `axi status` run object reports its terminal result through its own outcome
# field as well, which fm_nm_run_is_active below checks directly.
fm_nm_run_status_class() {  # <status_word>
  case "${1:-}" in
    completed|failed|cancelled) printf 'terminal' ;;
    running)                    printf 'live' ;;
    *)                          printf 'unknown' ;;
  esac
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

# Descriptions from the gate findings table in captured `axi status` TOON $1.
# Read the declared column order and respect quoted commas and escaped quotes,
# so finding IDs and file paths cannot supply classification context.
fm_nm_finding_descriptions() {  # <toon-output>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*findings\[[0-9]+\]\{/ {
      hdr = match($0, /[^ \t]/) - 1; inblk = 1; description = 0
      fields = $0; sub(/^[^{]*\{/, "", fields); sub(/\}.*/, "", fields)
      count = split(fields, names, ",")
      for (i = 1; i <= count; i++) if (names[i] == "description") description = i
      next
    }
    inblk {
      if ($0 ~ /^[[:space:]]*$/) { inblk = 0; next }
      if (match($0, /[^ \t]/) - 1 <= hdr) { inblk = 0; next }
      field = 1; quoted = 0; value = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (quoted && c == "\\") { c = substr($0, ++i, 1) }
        else if (c == "\"") { quoted = !quoted; continue }
        else if (!quoted && c == ",") {
          if (field == description) break
          field++; continue
        }
        if (field == description) value = value c
      }
      if (description && field == description) print value
    }
  '
}

# The first finding description in captured `axi status` TOON $1 that reports a
# configured check COULD NOT RUN, printed as evidence; 1 when there is none.
fm_nm_unrunnable_check_finding() {  # <toon-output>
  local row
  row=$(fm_nm_finding_descriptions "$1" |
    grep -iE '(^|[^[:alnum:]_])(checks?|lint|linter|eslint|prettier|formatter|test runner|vitest|jest|command not found)([^[:alnum:]_]|$)' |
    grep -iE 'could ?n[^ ]{0,3}t (be )?run|could not (be )?run|can ?n[^ ]{0,3}t (be )?run|cannot (be )?run|can not (be )?run|unable to run|did ?n[^ ]{0,3}t run|did not run|was not run|were not run|never ran|not runnable|command not found' | head -1)
  [ -n "$row" ] || return 1
  printf '%s' "$(fm_nm_trim "$row")"
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
# The one exception to newest-row-decides is the live-over-terminal rule stated
# with fm_nm_head_matches_worktree above, and it only ever replaces a TERMINAL
# answer with a LIVE one: when the newest row binds but is terminal, the older
# rows are scanned for a live row that ALSO binds to this worktree, and that
# row's status word is printed instead. A live row whose head resolves in this
# copy binds by fm_nm_head_matches_worktree. A live row whose head does NOT
# resolve (the routine shape: the pipeline's fix-round commits live only in the
# gate repo) binds ONLY when the held terminal row sits at EXACTLY the worktree
# HEAD - the same exact-equality anchor the pipeline-continuation rule above
# requires, so branch-name coincidence and other tasks' runs still never
# match. A terminal newest row is the corpse of a crashed attempt whenever a
# live run for the same worktree is still on the ledger, so it is not the
# present. Nothing else widens: a newest row that does not bind still ends the
# scan, a newest row whose class is live or unclassifiable is still answered
# as-is, the anchored pipeline-continuation path is untouched, and with no live
# sibling the newest terminal word is still what is printed.
# Read-only: git reads resolve objects in place; custody never changes.
fm_nm_runs_status_for_worktree() {  # <worktree> <branch> <runs-list-output> [expected-head]
  local wt=$1 branch=$2 list=$3 expected_head=${4:-}
  local local_full row_full row st br sha day clock pr extra year_num month_num day_num max_day pending_st=''
  # Set only by the newest binding row when its status classifies terminal, and
  # printed when the scan ends without finding a live row for this worktree. It
  # is the sole reason the scan continues past the newest row, and every exit
  # below leaves the loop rather than returning, so a malformed older row can
  # never swallow an answer the newest row had already decided.
  local decided='' decided_exact=''
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 0
  [ -n "$list" ] || return 0
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    IFS=$' \t' read -r st br sha day clock pr extra <<< "$row"
    [ -n "$st" ] && [ -n "$br" ] && [ -n "$sha" ] && [ -n "$day" ] && [ -n "$clock" ] || break
    [ -z "$extra" ] || break
    case "$st" in *[!a-z_-]*|'') break ;; esac
    case "$br" in *[!A-Za-z0-9._/-]*|'') break ;; esac
    case "$sha" in *[!A-Fa-f0-9]*|'') break ;; esac
    case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) break ;; esac
    case "$clock" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) break ;; esac
    case "$pr" in ''|https://*) ;; *) break ;; esac
    [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || break
    year_num=$((10#${day%%-*}))
    month_num=${day#*-}; month_num=${month_num%%-*}; month_num=$((10#$month_num))
    day_num=$((10#${day##*-}))
    [ "$year_num" -gt 0 ] && [ "$month_num" -ge 1 ] && [ "$month_num" -le 12 ] || break
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
    [ "$day_num" -ge 1 ] && [ "$day_num" -le "$max_day" ] || break
    [ "$br" = "$branch" ] || continue
    if [ -n "$decided" ]; then
      # Live-over-terminal: the newest row bound to this worktree but is a
      # terminal record, so the older rows are searched for a live run that
      # binds to the same worktree by the same head rule. Only such a row
      # displaces the held terminal word; anything else leaves it standing.
      [ "$(fm_nm_run_status_class "$st")" = live ] || continue
      if [ -n "$(fm_nm_resolve_commit "$wt" "$sha")" ]; then
        fm_nm_head_matches_worktree "$wt" "$sha" || continue
      else
        [ -n "$decided_exact" ] || continue
      fi
      decided=$st
      break
    fi
    if [ -n "$pending_st" ]; then
      # This is the row immediately older than the active unresolvable row:
      # the only admissible anchor, and only exact head equality proves the
      # worktree still sits at the submitted head.
      if [ "$(fm_nm_resolve_commit "$wt" "$sha")" = "$local_full" ]; then
        decided=$pending_st
      fi
      break
    fi
    if [ -n "$expected_head" ]; then
      case "$expected_head" in *[!A-Fa-f0-9]*|'') break ;; esac
      [ "${#expected_head}" -ge 7 ] && [ "${#expected_head}" -le 40 ] || break
      case "$expected_head" in
        "$sha"*) ;;
        *) case "$sha" in "$expected_head"*) ;; *) break ;; esac ;;
      esac
    fi
    row_full=$(fm_nm_resolve_commit "$wt" "$sha")
    if [ -n "$row_full" ]; then
      if fm_nm_head_matches_worktree "$wt" "$sha"; then
        decided=$st
        # A live or unclassifiable word is this worktree's current answer and
        # ends the scan; only a terminal one keeps looking for a live sibling.
        if [ "$(fm_nm_run_status_class "$st")" = terminal ]; then
          [ "$row_full" != "$local_full" ] || decided_exact=1
          continue
        fi
      fi
      break
    fi
    [ "$st" = running ] || break
    pending_st=$st
  done <<< "$list"
  printf '%s' "$decided"
  return 0
}
