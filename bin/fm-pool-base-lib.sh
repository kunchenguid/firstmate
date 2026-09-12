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
# not something to silently build on.
#
# A task that records no delivery mode at all - a scout, which opens no PR and
# lands nothing - keeps origin authoritative too. KNOWN LIMIT, accepted
# deliberately: on an origin-backed `local-only` project a scout therefore reads
# a base missing the locally landed commits. That is what every task did before
# this change, so it is a gap this change does not close rather than one it
# opens, and closing it would mean deciding a task question from the project
# registry, which the paragraph above rules out. It does not arise without an
# origin, where the local default branch is the base in every mode.
#
# A project with no origin at all is not decided here: there is no origin to be
# authoritative, so its local default branch is the only base, in every mode.

# 0 when the local default branch, not origin, carries this task's landed work
# and is therefore the base to use.
fm_pool_base_prefers_local_default() {  # <repo> <task-mode> <origin-commit> <local-commit>
  local repo=$1 mode=$2 origin_commit=$3 local_commit=$4
  [ "$mode" = local-only ] || return 1
  [ -n "$origin_commit" ] && [ -n "$local_commit" ] || return 1
  [ "$origin_commit" != "$local_commit" ] || return 1
  git -C "$repo" merge-base --is-ancestor "$origin_commit" "$local_commit" 2>/dev/null
}
