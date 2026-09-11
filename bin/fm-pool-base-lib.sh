#!/usr/bin/env bash
# Where a task's landed work lives, for the two places that must start from
# it: the pooled base a spawn launches on (freshen_spawn_worktree_base in
# bin/fm-spawn.sh) and the base a branch is reviewed against
# (bin/fm-review-diff.sh). Both ask the same question, so they ask it here.
#
# Which ref carries landed work depends on how the task delivers. A task
# delivered through a PR lands on origin, so origin's default branch is
# authoritative and nothing below applies to it. A `local-only` task lands
# through bin/fm-merge-local.sh, which merges into the LOCAL default branch and
# never pushes, so origin's tip is missing work the captain has already
# approved. Starting from origin there hands the next task a base from before
# that merge, and its branch then reads as a revert of the landed work.
#
# The key is the TASK's delivery mode, not the project's registered posture:
# bin/fm-merge-local.sh gates the local landing on the mode recorded in
# state/<id>.meta, and a spawn is allowed to deviate from the registry
# (bin/fm-spawn.sh's rigor notice), so a registry answer would be wrong in both
# directions - a local-only task on a no-mistakes project would still be handed
# a stale base, and a no-mistakes task on a local-only project would carry
# unpushed local commits into its PR.
#
# So the local default branch wins only for a `local-only` task, and then only
# when it strictly contains origin's tip: it holds everything origin has plus
# the locally landed work, and nothing can be lost by starting there. Equal
# means the same commit and origin stands. Behind or diverged both keep origin
# authoritative, because a local branch that does not contain origin's tip is
# not something to silently build on. A mode that does not resolve keeps origin
# too, so the answer is never a guess.
#
# A project with no origin at all is not decided here: there is no origin to be
# authoritative, so its local default branch is the only base, in every mode.

FM_POOL_BASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 0 when work delivered this way lands on the LOCAL default branch.
#
# A scout records no delivery mode: it opens no PR and lands nothing, so no task
# fact exists to read and the captain's registered posture for the project is
# the best available answer for where that project's work lands.
# bin/fm-project-mode.sh owns that registry read, including its fallback to
# no-mistakes for an unknown project or an unknown mode.
fm_pool_base_lands_locally() {  # <project-path> <task-mode>
  local project=$1 mode=$2
  if [ -z "$mode" ]; then
    mode=$(FM_HOME="${FM_HOME:-}" FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-}" \
      "$FM_POOL_BASE_LIB_DIR/fm-project-mode.sh" "$(basename "$project")" 2>/dev/null \
      | cut -d' ' -f1) || return 1
  fi
  [ "$mode" = local-only ]
}

# 0 when the local default branch, not origin, carries this task's landed work
# and is therefore the base to use.
fm_pool_base_prefers_local_default() {  # <repo> <project-path> <task-mode> <origin-commit> <local-commit>
  local repo=$1 project=$2 mode=$3 origin_commit=$4 local_commit=$5
  [ -n "$origin_commit" ] && [ -n "$local_commit" ] || return 1
  [ "$origin_commit" != "$local_commit" ] || return 1
  fm_pool_base_lands_locally "$project" "$mode" || return 1
  git -C "$repo" merge-base --is-ancestor "$origin_commit" "$local_commit" 2>/dev/null
}
