#!/usr/bin/env bash
# fm-upstream-check.sh - Inspect new upstream commits without merging.
#
# For fork-with-local-customizations installations: the read-only inspection
# half of selective upstream integration. Runs inside any git repository that
# has an upstream remote; fetches it, then prints each commit in upstream's
# default branch that is not yet in the local branch, oldest first. Never
# merges, never pushes, never touches the working tree. Pair with the
# upstream-integrate skill for the interactive + worker-dispatch half; pair
# with /updatefirstmate for the fast-forward path that fits when the local
# branch has not diverged.
#
# Usage: fm-upstream-check.sh [options]
#   --remote <name>    upstream remote to fetch from
#                      (default: config/upstream-remote, else "upstream")
#   --local <branch>   local branch to compare (default: current branch)
#   --no-fetch         skip the fetch step, use already-fetched refs
#   -h, --help         print this help and exit
#
# Output: one block per new upstream commit, oldest first:
#   <short-sha> <subject>
#     author: <name> <<email>>
#     date:   <YYYY-MM-DD>
#     files:  <file1>, <file2>, ...
#   (blank line between commits)
# When the local branch has every upstream commit, prints exactly: up to date
#
# Remote resolution: --remote wins; otherwise config/upstream-remote (one
# line, one token) at the repository root; otherwise "upstream". The remote
# must exist; an unknown remote exits non-zero with a single diagnostic line
# on stderr.
#
# Local branch resolution: --local wins; otherwise the current branch. The
# script does not switch branches. A detached HEAD exits non-zero with a
# single diagnostic line, since "what is new upstream" is ambiguous then.
#
# Upstream branch resolution: refs/remotes/<remote>/HEAD, falling back to
# <remote>/main, then <remote>/master. The script does not assume "main".
#
# Exit status: 0 on success (including "up to date"), 1 on a usage, remote,
# branch, or fetch error.

set -eu

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: not inside a git repository" >&2
  exit 1
}

REMOTE=""
LOCAL_BRANCH=""
NO_FETCH=0

usage() {
  sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remote)
      [ $# -ge 2 ] || { echo "error: --remote requires a value" >&2; exit 1; }
      REMOTE=$2
      shift 2
      ;;
    --local)
      [ $# -ge 2 ] || { echo "error: --local requires a value" >&2; exit 1; }
      LOCAL_BRANCH=$2
      shift 2
      ;;
    --no-fetch)
      NO_FETCH=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage 1
      ;;
  esac
done

# Resolve the upstream remote name: flag, then config/upstream-remote, then "upstream".
if [ -z "$REMOTE" ]; then
  if [ -f "$REPO_ROOT/config/upstream-remote" ]; then
    REMOTE=$(head -1 "$REPO_ROOT/config/upstream-remote" | tr -d '[:space:]')
  fi
  : "${REMOTE:=upstream}"
fi

# Verify the remote exists. A typo here is the most common fork-setup mistake.
if ! git -C "$REPO_ROOT" remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "error: remote '$REMOTE' not found; set config/upstream-remote or pass --remote" >&2
  exit 1
fi

# Resolve the local branch to compare. Never switch.
if [ -z "$LOCAL_BRANCH" ]; then
  LOCAL_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
  if [ "$LOCAL_BRANCH" = "HEAD" ]; then
    echo "error: HEAD is detached; pass --local to name the branch to compare" >&2
    exit 1
  fi
fi

# Resolve the upstream branch: <remote>/HEAD, then <remote>/main, then <remote>/master.
resolve_upstream_ref() {
  local r=$1 ref
  ref=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short "refs/remotes/$r/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  local b
  for b in main master; do
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/$r/$b" >/dev/null 2>&1; then
      printf 'refs/remotes/%s/%s\n' "$r" "$b"
      return 0
    fi
  done
  return 1
}

if ! UPSTREAM_REF=$(resolve_upstream_ref "$REMOTE"); then
  echo "error: could not resolve default branch for remote '$REMOTE'" >&2
  exit 1
fi

# Fetch unless suppressed. --no-fetch lets tests run without network and lets
# a captain re-print a summary from already-fetched refs.
if [ "$NO_FETCH" -eq 0 ]; then
  if ! git -C "$REPO_ROOT" fetch "$REMOTE" --prune --quiet 2>/dev/null; then
    echo "error: fetch from '$REMOTE' failed (network or auth)" >&2
    exit 1
  fi
fi

# Count new upstream commits first so the "up to date" case does not spin up a
# per-commit loop that prints nothing.
NEW_COUNT=$(git -C "$REPO_ROOT" rev-list --reverse "$LOCAL_BRANCH..$UPSTREAM_REF" 2>/dev/null | wc -l | tr -d '[:space:]')

if [ "${NEW_COUNT:-0}" -eq 0 ]; then
  echo "up to date"
  exit 0
fi

git -C "$REPO_ROOT" rev-list --reverse "$LOCAL_BRANCH..$UPSTREAM_REF" 2>/dev/null \
  | while IFS= read -r sha; do
      short=$(git -C "$REPO_ROOT" rev-parse --short "$sha")
      subject=$(git -C "$REPO_ROOT" log -1 --format='%s' "$sha")
      author=$(git -C "$REPO_ROOT" log -1 --format='%an <%ae>' "$sha")
      date=$(git -C "$REPO_ROOT" log -1 --format='%ad' --date=short "$sha")
      files=$(git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$sha" | paste -sd ', ' -)
      printf '%s %s\n' "$short" "$subject"
      printf '  author: %s\n' "$author"
      printf '  date:   %s\n' "$date"
      printf '  files:  %s\n' "$files"
      printf '\n'
    done
