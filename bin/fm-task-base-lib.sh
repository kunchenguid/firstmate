#!/usr/bin/env bash
# Single owner of a task's TWO base references. A dispatched worker needs two
# different commits and today's spawn path supplies only one, so a brief citing
# a file or a line number is silently unreliable whenever they differ:
#
#   slot base           the commit the task's worktree is placed at, so reads,
#                       greps, line citations and running the code all resolve
#                       against what the fleet ACTUALLY RUNS. This is the local
#                       default-branch tip of the project checkout - the same
#                       local-HEAD target secondmates already sync to, and no
#                       fetch is involved.
#   contribution target the commit the task's branch is CUT FROM, so the PR
#                       carries only the task's own commits. On a fork setup
#                       that is the upstream trunk, which is NOT the slot base.
#
# Cutting the branch from the slot base instead is the pollution this file
# exists to prevent: it silently carries every fleet-only commit into the
# contribution. Resetting the slot to the contribution target instead dispatches
# the task onto a trunk missing the code it edits. Neither single ref satisfies
# both roles, so both are resolved, recorded, and stated separately.
#
# Sourced by bin/fm-spawn.sh (resolves and records them) and bin/fm-brief.sh
# (states them to the worker). Depends on bin/fm-ff-lib.sh for default_branch
# and primary_head_commit.
#
# task_base_resolve <repo-dir> sets, and clears first:
#   TASK_BASE_SLOT          slot base commit SHA
#   TASK_BASE_SLOT_REF      the ref it was read from
#   TASK_BASE_CONTRIB       contribution target commit SHA (empty when unresolved)
#   TASK_BASE_CONTRIB_REF   the ref it was read from (or the one that failed)
#   TASK_BASE_STATE         coincident | distinct | unresolved
#   TASK_BASE_ERROR         human-readable reason when resolution degraded
#
# TASK_BASE_STATE is the whole contract in one word:
#   coincident  no distinct upstream, or upstream is already the slot base.
#               The two roles collapse to one commit and nothing changes.
#   distinct    the two differ. The worker MUST be told: read at the slot base,
#               cut its branch at the contribution target.
#   unresolved  an upstream relationship exists but its trunk cannot be read
#               locally. Refused rather than guessed, because silently falling
#               back to the slot base is exactly the pollution above.

# shellcheck disable=SC2034 # The resolution outputs are read by callers (fm-spawn.sh) and tests, not by this lib.
TASK_BASE_SLOT='' TASK_BASE_SLOT_REF='' TASK_BASE_CONTRIB='' TASK_BASE_CONTRIB_REF='' TASK_BASE_STATE='' TASK_BASE_ERROR=''

# Normalize a remote URL for comparison: trailing slash and .git suffix only.
# Deliberately not a URL parser - scheme/host differences are real differences.
task_base_normalize_url() {  # <url>
  local url=${1%/}
  printf '%s\n' "${url%.git}"
}

# Name the remote-tracking ref that holds the UPSTREAM trunk, when this repo
# contributes somewhere other than where it pushes. Two shapes are recognized:
#   1. a separate `upstream` remote (the conventional fork layout), and
#   2. an `origin` whose fetch URL differs from its push URL, which is the
#      layout firstmate itself uses - origin FETCHES upstream and PUSHES the
#      fork, so `origin/<default>` is the upstream trunk while local
#      `<default>` is the fork trunk.
# Prints the ref name, or returns 1 when no distinct upstream exists.
task_base_upstream_ref() {  # <repo-dir>
  local dir=$1 default fetch push
  if git -C "$dir" remote get-url upstream >/dev/null 2>&1; then
    default=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/upstream/HEAD 2>/dev/null) \
      && { printf '%s\n' "$default"; return 0; }
    default=$(default_branch "$dir") || return 1
    printf 'upstream/%s\n' "$default"
    return 0
  fi
  fetch=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  push=$(git -C "$dir" remote get-url --push origin 2>/dev/null) || return 1
  [ "$(task_base_normalize_url "$fetch")" != "$(task_base_normalize_url "$push")" ] || return 1
  default=$(default_branch "$dir") || return 1
  printf 'origin/%s\n' "$default"
}

task_base_resolve() {  # <repo-dir>
  local dir=$1 upstream_ref upstream_sha
  TASK_BASE_SLOT=
  TASK_BASE_SLOT_REF=
  TASK_BASE_CONTRIB=
  TASK_BASE_CONTRIB_REF=
  TASK_BASE_STATE=
  TASK_BASE_ERROR=

  TASK_BASE_SLOT_REF=$(default_branch "$dir" 2>/dev/null) || {
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="no default branch in $dir"
    return 1
  }
  TASK_BASE_SLOT=$(primary_head_commit "$dir") || {
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="default branch $TASK_BASE_SLOT_REF has no commit in $dir"
    return 1
  }

  # No distinct upstream: the two roles collapse onto the slot base and every
  # caller stays on today's single-reference behavior.
  if ! upstream_ref=$(task_base_upstream_ref "$dir"); then
    TASK_BASE_CONTRIB=$TASK_BASE_SLOT
    TASK_BASE_CONTRIB_REF=$TASK_BASE_SLOT_REF
    TASK_BASE_STATE=coincident
    return 0
  fi

  TASK_BASE_CONTRIB_REF=$upstream_ref
  if ! upstream_sha=$(git -C "$dir" rev-parse --verify --quiet "$upstream_ref^{commit}" 2>/dev/null); then
    # Refuse to guess. Falling back to the slot base here would cut the branch
    # at the fork trunk and carry every fleet-only commit into the PR.
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="upstream trunk $upstream_ref is not readable locally (never fetched?)"
    return 0
  fi
  TASK_BASE_CONTRIB=$upstream_sha
  if [ "$upstream_sha" = "$TASK_BASE_SLOT" ]; then
    TASK_BASE_STATE=coincident
  else
    TASK_BASE_STATE=distinct
  fi
  return 0
}

# The pollution guard. A branch cut from the contribution target descends from
# it, so the target is an ancestor of the branch head and `target..branch` holds
# only the task's own commits. A branch cut from the slot base instead does NOT
# descend from a diverged upstream target, and this fails - which is the whole
# point: it catches the polluted branch whether or not the worker has committed
# anything on top yet.
# Returns 0 clean, 1 polluted, 2 when a ref cannot be read.
task_base_verify_branch() {  # <repo-dir> <contribution-target> <branch-ref>
  local dir=$1 target=$2 branch=$3 target_sha branch_sha
  TASK_BASE_ERROR=
  target_sha=$(git -C "$dir" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="contribution target '$target' is not a readable commit"
    return 2
  }
  branch_sha=$(git -C "$dir" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="branch '$branch' is not a readable commit"
    return 2
  }
  if git -C "$dir" merge-base --is-ancestor "$target_sha" "$branch_sha"; then
    return 0
  fi
  local extra
  extra=$(git -C "$dir" rev-list --count "$target_sha..$branch_sha" 2>/dev/null || echo '?')
  TASK_BASE_ERROR="branch '$branch' does not descend from contribution target '$target'; it carries $extra commit(s) absent from that target, so a PR from it would contribute work the target never had"
  return 1
}
