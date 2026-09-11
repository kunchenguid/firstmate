#!/usr/bin/env bash
# Where a project's landed work lives, for the two places that must start from
# it: the pooled base a spawn launches on (freshen_spawn_worktree_base in
# bin/fm-spawn.sh) and the base a branch is reviewed against
# (bin/fm-review-diff.sh). Both ask the same question, so they ask it here.
#
# Which ref carries landed work depends on how the project lands it. A project
# delivered through a PR lands on origin, so origin's default branch is
# authoritative and nothing below applies to it. A `local-only` project lands
# through bin/fm-merge-local.sh, which merges into the LOCAL default branch and
# never pushes, so origin's tip is missing work the captain has already
# approved. Starting from origin there hands the next task a base from before
# that merge, and its branch then reads as a revert of the landed work.
#
# So the local default branch wins only for a project registered `local-only`,
# and then only when it strictly contains origin's tip: it holds everything
# origin has plus the locally landed work, and nothing can be lost by starting
# there. Equal means the same commit and origin stands. Behind or diverged both
# keep origin authoritative, because a local branch that does not contain
# origin's tip is not something to silently build on. A mode that does not
# resolve keeps origin too, so the answer is never a guess.
#
# A project with no origin at all is not decided here: there is no origin to be
# authoritative, so its local default branch is the only base, in every mode.

FM_POOL_BASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 0 when the project is registered as landing approved work on its LOCAL default
# branch. bin/fm-project-mode.sh owns that registry read, including its fallback
# to no-mistakes for an unknown project or an unknown mode.
fm_pool_base_lands_locally() {  # <project-path>
  local mode
  mode=$(FM_HOME="${FM_HOME:-}" FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-}" \
    "$FM_POOL_BASE_LIB_DIR/fm-project-mode.sh" "$(basename "$1")" 2>/dev/null \
    | cut -d' ' -f1) || return 1
  [ "$mode" = local-only ]
}

# 0 when the local default branch, not origin, carries this project's landed
# work and is therefore the base to use.
fm_pool_base_prefers_local_default() {  # <repo> <project-path> <origin-commit> <local-commit>
  local repo=$1 project=$2 origin_commit=$3 local_commit=$4
  [ -n "$origin_commit" ] && [ -n "$local_commit" ] || return 1
  [ "$origin_commit" != "$local_commit" ] || return 1
  fm_pool_base_lands_locally "$project" || return 1
  git -C "$repo" merge-base --is-ancestor "$origin_commit" "$local_commit" 2>/dev/null
}
