#!/usr/bin/env bash
# Seed the first commit of a genuinely brand-new, zero-commit GitHub repo, so its
# default branch exists and a crewmate can get a worktree at all: git cannot
# create a worktree for a branch with zero commits, and gh-axi repo create does
# not auto-initialize with a README, so a just-created empty repo is otherwise a
# dead end no crewmate can reach and firstmate is not allowed to write to.
#
# This is the sixth sanctioned exception to AGENTS.md hard rule #1 "never write
# to a project" (see section 1 and section 6), and it is narrow by construction:
# it only ever runs one `git commit --allow-empty` and pushes it, and only after
# verifying live against the GitHub API - never by trusting a flag or argument -
# that the repo has zero commits reachable from every branch. That verification
# is the entire safety net here, so any existing history, on any branch, is
# refused loudly and nothing is pushed. No file content, no other commits, no
# force-push, ever.
# Usage: fm-seed-empty-repo.sh <project-dir-or-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-seed-empty-repo.sh <project-dir-or-name>" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 1 ] || { usage; exit 1; }

# resolve_project_arg <arg>: same convention as fm-fleet-sync.sh - accept a path
# used as-is when it already exists, or a bare "<name>"/"projects/<name>" form
# resolved against $PROJECTS. Falls back to the raw argument unresolved so a
# genuinely bad path still hits the existence check below.
resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
    */*)
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
    *)
      candidate="$PROJECTS/$arg"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$arg"
}

PROJ=$(resolve_project_arg "$1")
[ -d "$PROJ" ] || { echo "error: no project directory at $PROJ" >&2; exit 1; }
git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: $PROJ is not a git repository" >&2; exit 1; }

REMOTE_URL=$(git -C "$PROJ" remote get-url origin 2>/dev/null) \
  || { echo "error: $PROJ has no origin remote" >&2; exit 1; }

# Parse owner/repo from an https or ssh GitHub remote URL; same pattern as
# bin/fm-bearings-snapshot.sh's repo_slug.
SLUG=$(printf '%s' "$REMOTE_URL" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##; s#/$##')
[ -n "$SLUG" ] || { echo "error: origin remote '$REMOTE_URL' is not a GitHub repository" >&2; exit 1; }
OWNER=${SLUG%%/*}
REPO=${SLUG#*/}

command -v gh-axi >/dev/null 2>&1 \
  || { echo "error: gh-axi is required to verify repo emptiness" >&2; exit 1; }

# --- The entire safety net: verify live, via the GitHub API, that $OWNER/$REPO
# genuinely has zero commits reachable from every branch. Never trust a flag or
# argument for this; refuse loudly on anything that is not an unambiguous
# confirmation of emptiness. ---

REPO_INFO=$(gh-axi api "/repos/$OWNER/$REPO" 2>&1) || {
  echo "REFUSED: could not read repo info for $OWNER/$REPO via the GitHub API: $REPO_INFO" >&2
  exit 1
}
SIZE=$(printf '%s\n' "$REPO_INFO" | sed -n 's/^size: *//p' | head -1)
case "$SIZE" in
  ''|*[!0-9]*)
    echo "REFUSED: could not parse repo size from the GitHub API response for $OWNER/$REPO" >&2
    exit 1
    ;;
esac
if [ "$SIZE" -ne 0 ]; then
  echo "REFUSED: $OWNER/$REPO has non-zero size ($SIZE); it is not a genuinely empty repo" >&2
  exit 1
fi

BRANCHES=$(gh-axi api "/repos/$OWNER/$REPO/branches" 2>&1) || {
  echo "REFUSED: could not list branches for $OWNER/$REPO via the GitHub API: $BRANCHES" >&2
  exit 1
}
case "$(printf '%s' "$BRANCHES" | tr -d '[:space:]')" in
  '[]')
    BRANCH_COUNT=0
    ;;
  *)
    BRANCH_COUNT=$(printf '%s\n' "$BRANCHES" | sed -n 's/^\[\([0-9]*\)\]:.*/\1/p' | head -1)
    ;;
esac
case "${BRANCH_COUNT:-}" in
  ''|*[!0-9]*)
    echo "REFUSED: could not parse branch count from the GitHub API response for $OWNER/$REPO" >&2
    exit 1
    ;;
esac
if [ "$BRANCH_COUNT" -ne 0 ]; then
  echo "REFUSED: $OWNER/$REPO already has $BRANCH_COUNT branch(es); it is not empty" >&2
  exit 1
fi

# The commits endpoint returns a 409 "Git Repository is empty" failure on a
# genuinely empty repo, and succeeds with real commit data otherwise. A success
# means real history exists somewhere and must refuse; a failure is only
# accepted as confirmation when it carries that expected empty-repo signature -
# any other failure (auth, rate limit, network) is inconclusive, not a
# confirmation, and must refuse just as loudly.
if COMMITS=$(gh-axi api "/repos/$OWNER/$REPO/commits?per_page=1" 2>&1); then
  echo "REFUSED: $OWNER/$REPO already has commit history via the commits API: $(printf '%s' "$COMMITS" | head -1)" >&2
  exit 1
fi
case "$COMMITS" in
  *[Ee]mpty*)
    :
    ;;
  *)
    echo "REFUSED: could not confirm $OWNER/$REPO has zero commits; the commits API call failed for an unexpected reason: $(printf '%s' "$COMMITS" | head -1)" >&2
    exit 1
    ;;
esac

# Verified empty on every branch: zero size, zero branches, and the commits API
# itself reports the repository as empty. Determine the branch to seed -
# prefer the remote's recorded default branch name, then the local clone's
# origin/HEAD symref, then "main".
DEFAULT_BRANCH=$(printf '%s\n' "$REPO_INFO" | sed -n 's/^default_branch: *//p' | head -1)
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
fi
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}

# A fresh clone of a genuinely empty repo already has local HEAD symbolically
# pointing at the right branch name (git reads that from the remote's HEAD
# symref even though the branch has no commit yet - "unborn"), so this is a
# safety check, not a normal setup step: refuse rather than guess if the local
# checkout disagrees with the remote-declared default.
CUR_BRANCH=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -z "$CUR_BRANCH" ]; then
  git -C "$PROJ" checkout --orphan "$DEFAULT_BRANCH" >/dev/null 2>&1 \
    || { echo "error: could not create local branch $DEFAULT_BRANCH in $PROJ" >&2; exit 1; }
elif [ "$CUR_BRANCH" != "$DEFAULT_BRANCH" ]; then
  echo "error: $PROJ is on local branch '$CUR_BRANCH', expected '$DEFAULT_BRANCH'; refusing to seed the wrong branch" >&2
  exit 1
fi

if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to seed a commit into it" >&2
  exit 1
fi

if git -C "$PROJ" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  echo "error: $PROJ's local $DEFAULT_BRANCH already has a commit; this exception only ever seeds the very first commit" >&2
  exit 1
fi

git -C "$PROJ" commit --allow-empty -m "Initial commit" >/dev/null
git -C "$PROJ" push origin "$DEFAULT_BRANCH" >/dev/null

echo "seeded: pushed the first commit to $OWNER/$REPO ($DEFAULT_BRANCH); $PROJ is ready for cloning and dispatch"
