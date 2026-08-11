#!/usr/bin/env bash
# Shared no-mistakes run attribution and snapshot-local query primitives.
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

# Fleet snapshots give each fm-crew-state.sh child the same private temporary
# directory and owner token. Only the two raw read-only queries used for run
# attribution participate. The primary result is bound to the canonical
# repository, branch, and current worktree HEAD; the coarse result is bound to
# the canonical repository. Exact key bytes are compared before reuse, so file
# names are never an identity proof.
fm_nm_snapshot_query() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 cache=${FM_NM_SNAPSHOT_CACHE_DIR:-}
  local token=${FM_NM_SNAPSHOT_CACHE_TOKEN:-} owner query common branch='' head=''
  local candidate entry=1 prefix output_tmp
  shift 2
  [ -n "$cache" ] && [ -n "$token" ] && [ -d "$cache" ] && [ ! -L "$cache" ] || return 1
  [ -f "$cache/.owner" ] && [ ! -L "$cache/.owner" ] || return 1
  IFS= read -r owner < "$cache/.owner" 2>/dev/null || return 1
  [ "$owner" = "$token" ] || return 1

  if [ "$#" -eq 2 ] && [ "$1" = axi ] && [ "$2" = status ]; then
    query=primary
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
    head=$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null) || return 1
  elif [ "$#" -eq 3 ] && [ "$1" = runs ] && [ "$2" = --limit ] && [ "$3" = 200 ]; then
    query=coarse
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  else
    return 1
  fi

  umask 077
  candidate="$cache/.key.$$"
  printf '%s\0%s\0%s\0%s\0' "$query" "$common" "$branch" "$head" > "$candidate" || return 1
  while :; do
    prefix="$cache/query-$entry"
    if [ -f "$prefix.key" ]; then
      if cmp -s "$candidate" "$prefix.key"; then
        rm -f "$candidate"
        if [ -f "$prefix.ready" ] && [ -f "$prefix.out" ]; then
          cat "$prefix.out"
          return 0
        fi
        break
      fi
    else
      if mv "$candidate" "$prefix.key" 2>/dev/null; then
        candidate=
        break
      fi
    fi
    entry=$((entry + 1))
  done
  [ -n "$candidate" ] && rm -f "$candidate"

  output_tmp="$cache/.out.$$"
  : > "$output_tmp" || return 1
  fm_nm_run_checked "$dir" "$timeout_secs" "$@" > "$output_tmp" || true
  if mv "$output_tmp" "$prefix.out" 2>/dev/null; then
    : > "$prefix.ready" || true
    cat "$prefix.out"
  else
    cat "$output_tmp"
    rm -f "$output_tmp"
  fi
  return 0
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  if fm_nm_snapshot_query "$@"; then
    return 0
  fi
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
