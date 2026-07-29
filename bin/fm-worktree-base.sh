#!/usr/bin/env bash
# Put a freshly acquired task worktree on the default branch its project
# actually ships to, before any branch is cut from it.
#
# WHY THIS EXISTS
# A fleet that ships to its own fork keeps origin as the shared upstream and a
# second remote for the fork; `bin/fm-update.sh` and `bin/fm-fleet-sync.sh` are
# built on that split, and every home runs the fork's default branch. The
# worktree pool is not: treehouse resets each pool worktree to
# refs/remotes/origin/HEAD, which is the UPSTREAM default branch, and it has no
# setting for anything else. A branch cut there starts on the wrong repository's
# history, so the pull request that follows carries every commit separating the
# two repositories - a six-commit change opening as twenty-six commits across a
# hundred and forty files - and merging it would sync the two repositories as an
# unannounced side effect.
#
# So the worktree is aligned here, at the one moment firstmate holds it and it
# is provably empty: after the pool hands it over and before the crewmate cuts
# its branch. The base repository is derived from configuration
# (bin/fm-pr-base-lib.sh), never hardcoded.
#
# It is a no-op for every ordinary project, where the base repository IS origin
# and the pool's starting commit is already right.
#
# UNLANDED WORK IS NEVER TOUCHED. Alignment happens only when the worktree is
# clean AND its HEAD is already contained in a remote-tracking branch. Anything
# else is reported and left exactly as it is, for a human to look at.
#
# Usage: fm-worktree-base.sh <worktree> [<source-checkout>]
#          Silent and exit 0 when the worktree is already on the right base or
#          the project has nothing to converge. One line on stdout when the
#          worktree was moved. Exit 1 with a diagnostic on stderr when the
#          worktree cannot be aligned - a spawn must stop rather than hand a
#          crewmate a branch point that produces an unreviewable pull request.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-base-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-base-lib.sh"

WT=${1:?usage: fm-worktree-base.sh <worktree> [<source-checkout>]}
SRC=${2:-$WT}

git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: $WT is not a git worktree" >&2
  exit 1
}

# An unresolvable base is not this script's problem to report: bin/fm-pr-base.sh
# owns that diagnostic, and a spawn must not fail on it.
fm_pr_base_resolve "$SRC" || exit 0

# The overwhelmingly common case: the project ships to its own origin, so the
# pool's starting commit is already the right one.
origin_url=$(git -C "$SRC" config --get remote.origin.url 2>/dev/null || true)
if fm_pr_base_url_identity "$origin_url" \
  && fm_pr_base_identity_equal "$FM_PR_BASE_URL_HOST" "$FM_PR_BASE_URL_PATH" \
    "$FM_PR_BASE_HOST" "$FM_PR_BASE_PATH"; then
  exit 0
fi

BASE_REMOTE=$FM_PR_BASE_REMOTE
if [ -z "$BASE_REMOTE" ]; then
  echo "error: $SRC opens pull requests against $FM_PR_BASE_HOST/$FM_PR_BASE_PATH but no remote fetches it, so a branch cannot be cut from its default branch" >&2
  exit 1
fi

# The remote's own advertised default branch, recorded once if it never was.
BASE_BRANCH=$(fm_pr_base_default_branch "$WT" "$BASE_REMOTE" 2>/dev/null || true)
if [ -z "$BASE_BRANCH" ]; then
  git -C "$WT" remote set-head "$BASE_REMOTE" --auto >/dev/null 2>&1 || true
  BASE_BRANCH=$(fm_pr_base_default_branch "$WT" "$BASE_REMOTE" 2>/dev/null || true)
fi
if [ -z "$BASE_BRANCH" ]; then
  echo "error: cannot determine $BASE_REMOTE's default branch in $WT, so a branch cannot be cut from $FM_PR_BASE_HOST/$FM_PR_BASE_PATH" >&2
  exit 1
fi

BASE_REF="refs/remotes/$BASE_REMOTE/$BASE_BRANCH"
if ! git -C "$WT" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
  git -C "$WT" fetch --quiet "$BASE_REMOTE" >/dev/null 2>&1 || true
fi
if ! git -C "$WT" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
  echo "error: $BASE_REF is missing in $WT, so a branch cannot be cut from $FM_PR_BASE_HOST/$FM_PR_BASE_PATH" >&2
  exit 1
fi

# Already part of the base branch's history: nothing to align.
if git -C "$WT" merge-base --is-ancestor HEAD "$BASE_REF" >/dev/null 2>&1; then
  exit 0
fi

# Hard rule: never tear down unlanded work. A worktree the pool just handed over
# is clean and sits on a published commit; anything else means work is present
# and this stops instead.
if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null || true)" ]; then
  echo "error: $WT is not on $BASE_REMOTE/$BASE_BRANCH but has uncommitted changes; refusing to move it - inspect the worktree" >&2
  exit 1
fi
if [ -z "$(git -C "$WT" branch -r --contains HEAD 2>/dev/null || true)" ]; then
  echo "error: $WT is not on $BASE_REMOTE/$BASE_BRANCH and its commit is on no remote; refusing to move it - inspect the worktree" >&2
  exit 1
fi

was=$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$WT" checkout --detach --quiet "$BASE_REF" >/dev/null 2>&1 || {
  echo "error: could not move $WT onto $BASE_REMOTE/$BASE_BRANCH" >&2
  exit 1
}
now=$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || echo unknown)
printf 'worktree base: %s moved from %s to %s/%s (%s), the branch %s/%s ships to\n' \
  "$WT" "$was" "$BASE_REMOTE" "$BASE_BRANCH" "$now" "$FM_PR_BASE_HOST" "$FM_PR_BASE_PATH"
