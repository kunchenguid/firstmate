#!/usr/bin/env bash
# fm-gate-fork-assert.sh - pre-flight the no-mistakes fork-push target.
#
# The no-mistakes gate pushes a validated branch and opens its PR at step 7 of 9
# (review -> test -> document -> lint -> push -> pr -> ci). When the current gh
# user has no write access to a gate-initialized repo's UPSTREAM, that push must
# go to a FORK instead, routed by the repo's fork_url in the local, gitignored
# gate DB (~/.no-mistakes/state.sqlite). That routing is a one-time hand-applied
# `no-mistakes init --fork-url ...` step: it is absent from a fresh gate DB, a
# reinstall, or a new firstmate home, and nothing else verifies it. When it is
# missing, the whole multi-hour review+test+doc+lint pipeline runs first and only
# THEN 403s at push, throwing the validated work away (5 of 20 historical
# firstmate runs died exactly this way). See data/fm-pr-stuck-w4/report.md.
#
# This check converts that multi-hour silent waste into a one-line session-start
# warning. For each gate-initialized repo whose UPSTREAM the current gh user
# cannot push to, it asserts the repo has a push-writable fork_url, and prints
# one GATE_FORK: line per repo that would 403 at push:
#
#   GATE_FORK: <working_path>: no push access to <upstream_slug> and <no fork
#   target|fork <fork_slug> not push-writable>; the next ship 403s at push after
#   the full pipeline. Fix: (cd <working_path> && no-mistakes init --fork-url
#   git@github.com:<gh_login>/<repo>.git)
#
# It exits non-zero when any repo is flagged, 0 when every repo is healthy. It is
# read-only (only `gh api` reads and a sqlite SELECT), detect-only, and
# best-effort: it stays silent and exits 0 when it cannot decide (no gate DB, no
# sqlite3, gh absent or unauthenticated - NEEDS_GH_AUTH owns that case, and a
# non-github upstream it cannot verify).
#
# bin/fm-bootstrap.sh runs it as a detect line, like the TANGLE guard, and
# bootstrap-diagnostics owns the response.
#
# Env:
#   FM_GATE_STATE_DB   override the gate DB path (default ~/.no-mistakes/state.sqlite)
set -u

DB=${FM_GATE_STATE_DB:-$HOME/.no-mistakes/state.sqlite}

# Silent, healthy no-op when we cannot decide: nothing to assert, or NEEDS_GH_AUTH
# (owned by bootstrap) already covers the missing/unauthenticated gh case.
[ -f "$DB" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
gh auth status >/dev/null 2>&1 || exit 0
GH_LOGIN=$(gh api user --jq .login 2>/dev/null || true)
[ -n "$GH_LOGIN" ] || exit 0

# Memoize push-access verdicts so repos sharing an upstream cost one gh call.
CACHE=$(mktemp "${TMPDIR:-/tmp}/fm-gate-fork.XXXXXX") || exit 0
trap 'rm -f "$CACHE"' EXIT

# Echo "owner/repo" for a github URL (https, ssh, or scp-style), or return 1 for
# any non-github or malformed URL (which we cannot verify and must not flag).
gate_github_slug() {
  local url=$1 rest
  case $url in
    https://github.com/*)   rest=${url#https://github.com/} ;;
    http://github.com/*)    rest=${url#http://github.com/} ;;
    ssh://git@github.com/*) rest=${url#ssh://git@github.com/} ;;
    git@github.com:*)       rest=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  rest=${rest%.git}
  rest=${rest%/}
  case $rest in
    */*/*) return 1 ;;              # more than owner/repo
    */*)
      [ -n "${rest%/*}" ] && [ -n "${rest#*/}" ] || return 1
      printf '%s\n' "$rest"
      return 0 ;;
  esac
  return 1
}

# Return 0 if the current gh user has push access to github slug $1. Memoized.
gate_can_push() {
  local slug=$1 verdict perm
  verdict=$(grep -F "	$slug	" "$CACHE" 2>/dev/null | cut -f1 || true)
  if [ -z "$verdict" ]; then
    perm=$(gh api "repos/$slug" --jq '.permissions.push // false' 2>/dev/null || true)
    [ "$perm" = true ] && verdict=push || verdict=nopush
    printf '%s\t%s\t\n' "$verdict" "$slug" >> "$CACHE"
  fi
  [ "$verdict" = push ]
}

problem=0
while IFS='|' read -r working_path upstream_url fork_url; do
  [ -n "$upstream_url" ] || continue
  upstream_slug=$(gate_github_slug "$upstream_url") || continue
  # Healthy: direct push access to the upstream, no fork needed.
  gate_can_push "$upstream_slug" && continue

  fork_state=
  if [ -z "$fork_url" ]; then
    fork_state="no fork target"
  else
    fork_slug=$(gate_github_slug "$fork_url" || true)
    if [ -z "$fork_slug" ] || ! gate_can_push "$fork_slug"; then
      fork_state="fork ${fork_slug:-$fork_url} not push-writable"
    fi
  fi
  [ -n "$fork_state" ] || continue

  repo_name=${upstream_slug#*/}
  printf 'GATE_FORK: %s: no push access to %s and %s; the next ship 403s at push after the full pipeline. Fix: (cd %s && no-mistakes init --fork-url git@github.com:%s/%s.git)\n' \
    "$working_path" "$upstream_slug" "$fork_state" "$working_path" "$GH_LOGIN" "$repo_name"
  problem=1
done < <(sqlite3 -separator '|' "$DB" "SELECT working_path, upstream_url, IFNULL(fork_url,'') FROM repos;" 2>/dev/null)

[ "$problem" -eq 0 ]
