#!/usr/bin/env bash
# fm-landed-lib.sh - the single owner of "has this content already landed?"
#
# WHY CONTENT, NOT COMMIT REACHABILITY
# `rev-list --count <ref>..HEAD` answers "is this COMMIT reachable from <ref>",
# which a squash merge, a rebase, or a local replay all break: the content is in
# the trunk under a different commit id, so the count stays non-zero forever.
# The question that actually protects work is "does <ref> already contain what
# HEAD introduces". A 3-way merge answers it: when HEAD adds nothing <ref> does
# not already have, the merged tree IS <ref>'s tree. Trunk commits past the
# merge-base do not count as "added", so an out-of-date slot still reads landed.
#
# WHY THE LANDING TARGET IS NOT ALWAYS refs/remotes/origin/<name>
# A remote-tracking ref is only the landing target for a fleet that pushes to
# that remote and refetches it. Two shapes in real use break that assumption:
#   - `origin` FETCHES from an upstream but PUSHES to a fork, so origin/<name>
#     tracks upstream while the fork trunk (the local branch) is where work
#     lands.
#   - A project that lands locally by design never advances origin/<name> at
#     all, so it drifts further behind every day.
# Callers therefore ask about a REF THEY CHOOSE. This library does not guess a
# landing target; fm_landed_default_branch_name resolves only the NAME, and each
# caller applies its own policy for which refs carrying that name to test.
#
# EXIT STATUS IS THREE-VALUED, ON PURPOSE
# fm_landed_tree_contains distinguishes "proven contained" from "proven not
# contained" from "could not tell". Collapsing the last two loses the difference
# between work that is demonstrably unlanded and a repository this could not
# read, and callers guarding real work need to refuse loudly on both while
# reporting them differently.
#
# Every read uses --no-optional-locks so inspecting a worktree that another lane
# owns never takes or rewrites its index lock.
set -u

# 0 when <ref> already contains everything HEAD introduces, 1 when it provably
# does not, 2 when that could not be determined (unreadable ref, unreadable
# HEAD, or a merge conflict, which means the trees genuinely diverge but is
# reported as inconclusive rather than as a clean "not contained").
fm_landed_tree_contains() {  # <dir> <ref>
  local dir=$1 ref=$2 ref_tree merged status
  ref_tree=$(git --no-optional-locks -C "$dir" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 2
  [ -n "$ref_tree" ] || return 2
  git --no-optional-locks -C "$dir" rev-parse --quiet --verify HEAD >/dev/null 2>&1 || return 2
  merged=$(git --no-optional-locks -C "$dir" merge-tree --write-tree "$ref" HEAD 2>/dev/null)
  status=$?
  # merge-tree exits non-zero on conflict AND on usage/read failure. Both are
  # inconclusive here: a conflict proves the trees diverge, but this predicate
  # only ever claims "demonstrably contained", never "demonstrably unlanded".
  [ "$status" -eq 0 ] || return 2
  merged=$(printf '%s\n' "$merged" | head -1)
  [ -n "$merged" ] || return 2
  [ "$merged" = "$ref_tree" ] && return 0
  return 1
}

# The default branch NAME (no refs/ prefix), preferring what origin/HEAD records
# and otherwise the first conventional name that exists as either a local branch
# or a remote-tracking branch. Non-zero when no name resolves, which every
# caller must treat as unverifiable rather than as "nothing to protect".
fm_landed_default_branch_name() {  # <dir>
  local dir=$1 ref branch
  ref=$(git --no-optional-locks -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git --no-optional-locks -C "$dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
      || git --no-optional-locks -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Every existing ref carrying <name> that could be a landing target, most-local
# first, one per line. The local branch leads because the two fleet shapes above
# both land there; a caller that needs the remote to win can reorder, and a
# caller that needs BOTH tested reads the whole list. Empty output (non-zero)
# means the name resolved but no ref carrying it exists.
fm_landed_candidate_refs() {  # <dir> <name>
  local dir=$1 name=$2 found=1 ref
  for ref in "refs/heads/$name" "refs/remotes/origin/$name"; do
    if git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      found=0
    fi
  done
  return "$found"
}
