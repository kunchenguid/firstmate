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

fm_nm_sql_literal() {  # <value>
  local value=${1-}
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

# Resolve the private no-mistakes state database without changing it.
# FM_NM_STATE_DB gives hermetic callers an explicit path.
# Production uses the same NM_HOME location the no-mistakes CLI owns.
# The _path form prints where the database is expected regardless of whether it
# exists, so an unavailability report can name the concrete path it looked at.
fm_nm_state_db_path() {
  local db=${FM_NM_STATE_DB:-}
  if [ -z "$db" ]; then
    db="${NM_HOME:-${HOME}/.no-mistakes}/state.sqlite"
  fi
  printf '%s\n' "$db"
}

fm_nm_state_db() {
  local db
  db=$(fm_nm_state_db_path)
  [ -f "$db" ] || return 1
  printf '%s\n' "$db"
}

# Resolve the no-mistakes run id this worktree owns into FM_NM_RUN_ID.
# The CLI's bare `axi status` resolver is process-ambient and may name another concurrent branch, so it is never an attribution source.
# The durable registry includes ids, branch, repo, head, status, and creation order; active rows win over terminal siblings, then newest starts win.
# Three outcomes, kept distinct so a caller never reads "the source was missing" as "there is no run":
#   0 with FM_NM_RUN_ID set    - this worktree owns that run; read it with `axi status --run <id>`.
#   0 with FM_NM_RUN_ID empty  - the registry was read and proves no run matches this worktree.
#   2                          - no durable source could be consulted; FM_NM_RUN_ID_UNAVAILABLE_REASON names the missing one.
# The result is assigned rather than printed so both halves survive without a
# second lookup; callers must not run it in a command substitution.
FM_NM_RUN_ID=
FM_NM_RUN_ID_UNAVAILABLE_REASON=

fm_nm_run_id_unavailable() {  # <reason>
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_NM_RUN_ID=
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_NM_RUN_ID_UNAVAILABLE_REASON=$1
  return 2
}

fm_nm_run_id_for_worktree() {  # <worktree> <branch>
  local wt=$1 branch=$2 db upstream query rows id run_head _status branch_query branch_rows
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_NM_RUN_ID=
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_NM_RUN_ID_UNAVAILABLE_REASON=
  [ -d "$wt" ] && [ -n "$branch" ] || return 0
  if ! command -v sqlite3 >/dev/null 2>&1; then
    fm_nm_run_id_unavailable "sqlite3 is not installed, so the no-mistakes run registry cannot be read"
    return 2
  fi
  if ! db=$(fm_nm_state_db); then
    fm_nm_run_id_unavailable "no no-mistakes state database at $(fm_nm_state_db_path)"
    return 2
  fi
  upstream=$(git -C "$wt" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$upstream" ]; then
    fm_nm_run_id_unavailable "no remote.origin.url in $wt, so no registry repo can be matched"
    return 2
  fi
  query="SELECT r.id, r.head_sha, r.status
FROM runs r
JOIN repos p ON p.id = r.repo_id
WHERE r.branch = $(fm_nm_sql_literal "$branch")
  AND p.upstream_url = $(fm_nm_sql_literal "$upstream")
ORDER BY CASE WHEN r.status IN ('pending', 'running', 'fixing', 'awaiting_approval', 'fix_review', 'ci') THEN 0 ELSE 1 END,
         r.created_at DESC;"
  if ! rows=$(sqlite3 -noheader -separator $'\t' "$db" "$query" 2>/dev/null); then
    fm_nm_run_id_unavailable "no-mistakes state database $db could not be queried"
    return 2
  fi
  if [ -z "$rows" ]; then
    # The registry records one upstream spelling per repo row, so the same
    # remote written as git@ here and https:// there matches nothing above.
    # A branch row whose head is this worktree's own code identity proves the
    # registry does hold this repo, so the miss is an unmatched upstream
    # string - an unavailable source, not proof that no run exists.
    branch_query="SELECT r.head_sha FROM runs r WHERE r.branch = $(fm_nm_sql_literal "$branch");"
    branch_rows=$(sqlite3 -noheader "$db" "$branch_query" 2>/dev/null) || branch_rows=
    if [ -n "$branch_rows" ]; then
      while IFS= read -r run_head; do
        [ -n "$run_head" ] || continue
        if fm_nm_head_matches_worktree "$wt" "$run_head"; then
          fm_nm_run_id_unavailable "no registry repo matches upstream $upstream (the run registry spells this remote differently)"
          return 2
        fi
      done <<< "$branch_rows"
    fi
    return 0
  fi
  while IFS=$'\t' read -r id run_head _status; do
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    fm_nm_head_matches_worktree "$wt" "$run_head" || continue
    # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
    FM_NM_RUN_ID=$id
    return 0
  done <<< "$rows"
  return 0
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
