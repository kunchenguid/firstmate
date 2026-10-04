# shellcheck shell=bash
# Shared positive proof that a commit's work has LANDED although its commits are
# not reachable from the default branch.
# Usage: . bin/fm-branch-landed-lib.sh, then call the fm_branch_landed_* functions.
#
# ONE OWNER for the two landed-work legs that bin/fm-teardown.sh's landed-work
# test and bin/fm-fleet-sync.sh's opt-in landed-branch prune both trust:
#   - fm_branch_landed_in_merged_pr: the forge reports the PR merged, and its head
#     contains the commit (ancestor, or every commit not on any remote has an
#     equivalent patch id in the PR head). An optional base also requires the PR
#     to have merged into that branch. fleet-sync passes its default branch.
#     Teardown passes none, so a PR merged into another task branch still counts.
#     An optional landed ref narrows "not on any remote" to "not in that ref".
#     fleet-sync passes its default ref, because it deletes the branch and a
#     commit held only by an unmerged remote branch has not landed. Teardown
#     passes none, because it also accepts remote reachability.
#   - fm_branch_landed_content_in_ref: a 3-way merge of the default ref with the
#     commit yields the default ref's own tree, so the commit introduces nothing
#     the default branch lacks (its change landed via squash).
# Squash merges collapse the branch's commits, so ancestry of the default branch
# proves nothing and per-commit patch ids against main no longer match.
# A pipeline rebase can leave a local copy diverged from the PR head, and a
# diverged copy is not treated as landed: path-set coverage, git cherry, and
# merge-tree containment each fail to prove content landed without also accepting
# unlanded edits to the same paths.
# Every function returns non-zero on any lookup error, missing object, merge
# conflict, or other inconclusive result, so a caller that deletes or discards
# on success keeps the work whenever evidence is missing.
# Each caller owns its own fetch and its own choice of which legs to trust:
# teardown also accepts remote reachability, which is not proof of landing.

# Resolve the PR number for <branch> via gh-axi, run from <repo> so it resolves
# that repository. Echoes the number on a match; returns non-zero on no match or
# any lookup failure, so the caller treats it as "no PR found".
fm_branch_landed_pr_number_from_branch() {  # <repo> <branch>
  local repo=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$repo" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_branch_landed_pr_number_from_target() {  # <pr-url-or-number>
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# The PR head commit can be absent locally once its branch is deleted, so fetch
# it through refs/pull/<n>/head, which the forge keeps after the branch is gone.
fm_branch_landed_ensure_commit() {  # <repo> <target> <commit>
  local repo=$1 target=$2 commit=$3 n
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_branch_landed_pr_number_from_target "$target") || return 1
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$repo" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_branch_landed_patch_id() {  # <repo> <commit>
  local repo=$1 commit=$2
  git -C "$repo" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# True when every commit of <commit> that no remote-tracking ref holds has an
# equivalent patch id in the PR head's own range. Commits a remote already holds
# stay reachable there, so only the remote-less ones need a match. With
# <landed-ref>, only commits that ref holds skip the match.
fm_branch_landed_unpushed_patches_in() {  # <repo> <commit> <pr-head> [<landed-ref>]
  local repo=$1 current=$2 pr_head=$3 landed_ref=${4:-} base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$repo" rev-parse --verify "$current^{commit}" 2>/dev/null) || return 1
  base=$(git -C "$repo" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$repo" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_branch_landed_patch_id "$repo" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  if [ -n "$landed_ref" ]; then
    unpushed=$(git -C "$repo" log --format=%H "$current" --not "$landed_ref" -- 2>/dev/null) || return 1
  else
    unpushed=$(git -C "$repo" log --format=%H "$current" --not --remotes -- 2>/dev/null) || return 1
  fi
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_branch_landed_patch_id "$repo" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the PR named by <target> merged, with a head that contains <commit>? Asks
# GitHub for the PR state, head, and URL from <repo>, and echoes the resolved PR
# URL on success. With <base>, the PR must also have merged into that branch.
# With <landed-ref>, the patch match skips only commits that ref holds.
# Returns non-zero when the PR is not merged, merged into another base, the
# commit is not contained in the PR head, or any gh or git error occurs.
fm_branch_landed_in_merged_pr() {  # <repo> <target> <commit> [<base>] [<landed-ref>]
  local repo=$1 target=$2 commit=$3 required_base=${4:-} landed_ref=${5:-} view state remainder head resolved_url base current
  local fields=state,headRefOid,url query='.state + "\t" + .headRefOid + "\t" + .url'
  [ -n "$target" ] || return 1
  if [ -n "$required_base" ]; then
    fields="$fields,baseRefName"
    query="$query"' + "\t" + .baseRefName'
  fi
  view=$(cd "$repo" && gh pr view "$target" --json "$fields" -q "$query" 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  if [ -n "$required_base" ]; then
    base=${resolved_url#*$'\t'}
    [ "$base" != "$resolved_url" ] || return 1
    resolved_url=${resolved_url%%$'\t'*}
    [ "$base" = "$required_base" ] || return 1
  fi
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_branch_landed_ensure_commit "$repo" "$target" "$head" || return 1
  current=$(git -C "$repo" rev-parse --verify "$commit^{commit}" 2>/dev/null) || return 1
  if ! git -C "$repo" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    fm_branch_landed_unpushed_patches_in "$repo" "$current" "$head" "$landed_ref" || return 1
  fi
  printf '%s' "$resolved_url"
}

# Is <commit>'s content already present in <ref>? 3-way merges <ref> with the
# commit: when the commit introduces nothing <ref> does not already contain, the
# merged tree equals <ref>'s tree. This isolates commit-only changes, so unrelated
# commits <ref> gained past the merge-base do not count as "added". Returns
# non-zero when inconclusive (no such ref, or a merge conflict). The caller
# fetches <ref> first when it must be current.
fm_branch_landed_content_in_ref() {  # <repo> <ref> <commit>
  local repo=$1 ref=$2 commit=$3 default_tree merged_tree
  default_tree=$(git -C "$repo" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$repo" merge-tree --write-tree "$ref" "$commit" 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}
