#!/usr/bin/env bash
# Shared "is this branch provably safe to delete?" decision procedures.
#
# ONE owner for the branch proofs and exact-tip deletion primitives used by
# fm-fleet-sync.sh, fm-teardown.sh, and fm-branch-cleanup.sh.
#
# The ancestor proof below says a local branch is provably safe to delete iff
# ALL of the following hold:
#   1. it exists as a local branch in the repo;
#   2. it is not currently checked out in ANY worktree of that repo, linked or
#      main - deleting a checked-out branch would fail anyway, but checking
#      first keeps this a pure decision procedure with no destructive side
#      effect on the caller's own probing;
#   3. its tip is an ancestor of the given "merged into" ref (a clean
#      fast-forward, or any non-squash merge, already contains it - git's own
#      `branch -d` can verify this itself).
# The separate gone-upstream proof preserves fleet-sync's established squash
# cleanup contract: a local branch whose upstream reads "[gone]" and which no
# worktree has checked out is eligible for local cleanup. It is deliberately
# not folded into the ancestor proof because a deleted remote ref alone does
# not prove merge outside that lifecycle contract.
#
# The GitHub-aware proof is the stronger fallback for squash merges and remote
# cleanup. It proves the exact candidate commit is contained in a merged PR
# head, or that applying the candidate to the current default adds no content.
# Remote deletion additionally uses an exact expected-old-value lease, so a
# branch that advances after proof is preserved rather than deleted.
# ANY uncertainty - the branch does not exist, a worktree still has it out, or
# neither proof holds - returns non-zero (NOT safe): fail safe, never force a
# delete this cannot prove. The caller decides what "not safe" means (leave it
# alone and move on, never an error worth failing over).

# fm_branch_worktree_branches <repo>: newline list of branch shortnames
# currently checked out in any worktree of <repo> (the main checkout included).
fm_branch_worktree_branches() {
  local repo=$1
  git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p'
}

fm_branch_worktree_has_branch() {
  local repo=$1 branch=$2
  fm_branch_worktree_branches "$repo" | grep -Fxq -- "$branch"
}

# fm_branch_default_branch <repo>: resolve the local default branch using the
# same origin/HEAD, main, master precedence shared by all cleanup callers.
fm_branch_default_branch() {
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# fm_branch_is_safely_merged <repo> <branch> <merged_into_ref> [expected_tip]:
# the proof itself (see header). When <expected_tip> is supplied, it additionally
# proves that is still the branch's current tip, binding a caller's later
# expected-old-value deletion to precisely the tip this proof examined. Never
# inspects or changes anything but refs. Refuses a
# <branch> that IS the "merged into" ref itself as a defensive guard against a
# caller accidentally naming the protected/default branch - every branch is
# trivially its own ancestor, so without this guard that self-comparison would
# otherwise look "safely merged".
fm_branch_is_safely_merged() {
  local repo=$1 branch=$2 merged_into=$3 expected_tip=${4:-} tip
  [ -n "$branch" ] || return 1
  [ "refs/heads/$branch" != "$merged_into" ] || return 1
  tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch") || return 1
  [ -z "$expected_tip" ] || [ "$tip" = "$expected_tip" ] || return 1
  fm_branch_worktree_has_branch "$repo" "$branch" && return 1
  if [ -n "$merged_into" ] \
    && git -C "$repo" merge-base --is-ancestor "$tip" "$merged_into" 2>/dev/null; then
    return 0
  fi
  return 1
}

# fm_branch_is_safely_gone <repo> <branch> [expected_tip]: the established
# fleet-sync squash cleanup proof. The optional expected tip binds a later
# deletion to the ref state the caller inspected.
fm_branch_is_safely_gone() {
  local repo=$1 branch=$2 expected_tip=${3:-} tip track
  [ -n "$branch" ] || return 1
  tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch") || return 1
  [ -z "$expected_tip" ] || [ "$tip" = "$expected_tip" ] || return 1
  fm_branch_worktree_has_branch "$repo" "$branch" && return 1
  track=$(git -C "$repo" for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>/dev/null)
  [ "$track" = "[gone]" ]
}

# fm_branch_delete_local_proven_tip <repo> <branch> <expected_tip>: delete the
# exact local tip a caller has already proved landed.
fm_branch_delete_local_proven_tip() {
  local repo=$1 branch=$2 expected_tip=$3 prune_worktree delete_status tip
  [ -n "$branch" ] && [ -n "$expected_tip" ] || return 1
  tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch") || return 1
  [ "$tip" = "$expected_tip" ] || return 1
  fm_branch_worktree_has_branch "$repo" "$branch" && return 1
  prune_worktree=$(mktemp -d /tmp/fm-branch-prune.XXXXXX) || return 1
  rmdir "$prune_worktree" || return 1
  git -C "$repo" worktree add -q "$prune_worktree" "$branch" || return 1
  git -C "$repo" update-ref -d "refs/heads/$branch" "$expected_tip" >/dev/null 2>&1
  delete_status=$?
  git -C "$repo" worktree remove "$prune_worktree" >/dev/null 2>&1 || true
  return "$delete_status"
}

# fm_branch_delete_if_safely_merged <repo> <branch> <merged_into_ref>: delete
# <branch> in <repo> only when fm_branch_is_safely_merged proves it, printing
# nothing itself (callers report their own outcome). `git branch -d` always
# judges mergedness against its checkout's HEAD, rather than an explicit ref.
# The shared exact-tip helper performs the final race-safe delete after this
# function establishes the ancestor proof.
# Returns non-zero, unchanged, for anything the proof does not cover.
fm_branch_delete_if_safely_merged() {
  local repo=$1 branch=$2 merged_into=$3 tip
  tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch") || return 1
  fm_branch_is_safely_merged "$repo" "$branch" "$merged_into" "$tip" || return 1
  fm_branch_delete_local_proven_tip "$repo" "$branch" "$tip"
}

fm_branch_delete_if_safely_gone() {
  local repo=$1 branch=$2 tip
  tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch") || return 1
  fm_branch_is_safely_gone "$repo" "$branch" "$tip" || return 1
  fm_branch_delete_local_proven_tip "$repo" "$branch" "$tip"
}

# fm_branch_remote_tip <repo> <remote> <branch>: print exactly one current
# remote branch tip.
# A missing remote or ref is an ordinary non-match.
fm_branch_remote_tip() {
  local repo=$1 remote=$2 branch=$3 out count
  git -C "$repo" remote get-url "$remote" >/dev/null 2>&1 || return 1
  out=$(git -C "$repo" ls-remote --heads "$remote" "refs/heads/$branch" 2>/dev/null) || return 1
  count=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d '[:space:]')
  [ "$count" = 1 ] || return 1
  printf '%s\n' "${out%%[[:space:]]*}"
}

# fm_branch_fetch_remote_tip <repo> <remote> <branch> <expected_tip>: fetch the
# named remote ref without creating a tracking ref, then prove FETCH_HEAD and
# the object both match the expected tip obtained immediately beforehand.
fm_branch_fetch_remote_tip() {
  local repo=$1 remote=$2 branch=$3 expected_tip=$4 fetched
  git -C "$repo" fetch --quiet "$remote" "refs/heads/$branch" >/dev/null 2>&1 || return 1
  fetched=$(git -C "$repo" rev-parse --verify --quiet FETCH_HEAD) || return 1
  [ "$fetched" = "$expected_tip" ] || return 1
  git -C "$repo" cat-file -e "$expected_tip^{commit}" 2>/dev/null
}

# fm_branch_delete_remote_proven_tip <repo> <remote> <branch> <expected_tip>:
# delete only the exact remote tip a caller has already proved landed. Missing
# remotes and refs are silent non-matches. The lease fails closed if the ref
# changes after inspection, and the worktree guard applies even though a remote
# delete would otherwise allow deleting the branch under a live task.
fm_branch_delete_remote_proven_tip() {
  local repo=$1 remote=$2 branch=$3 expected_tip=$4 current
  [ -n "$branch" ] && [ -n "$expected_tip" ] || return 1
  fm_branch_worktree_has_branch "$repo" "$branch" && return 1
  current=$(fm_branch_remote_tip "$repo" "$remote" "$branch") || return 1
  [ "$current" = "$expected_tip" ] || return 1
  git -C "$repo" push --quiet \
    --force-with-lease="refs/heads/$branch:$expected_tip" \
    "$remote" ":refs/heads/$branch" >/dev/null 2>&1
}

fm_branch_pr_number_from_branch() {
  local repo=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$(cd "$repo" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_branch_pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*) n=${target##*/pull/}; n=${n%%[!0-9]*} ;;
    [0-9]*) n=${target%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_branch_ensure_commit_object() {
  local repo=$1 target=$2 commit=$3 n
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_branch_pr_number_from_target "$target") || return 1
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$repo" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_branch_patch_id_for_commit() {
  local repo=$1 commit=$2
  git -C "$repo" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

fm_branch_unpushed_patches_are_in_pr_head() {
  local repo=$1 candidate=$2 pr_head=$3 base pr_patch_ids commit patch_id unpushed
  base=$(git -C "$repo" merge-base "$candidate" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$repo" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_branch_patch_id_for_commit "$repo" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$repo" log --format=%H "$candidate" --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_branch_patch_id_for_commit "$repo" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# fm_branch_pr_is_merged <repo> <branch> <pr-url-or-empty> <candidate>:
# reproduce teardown's exact merged-PR/head containment proof for an explicit
# candidate commit.
# Any GitHub or object uncertainty returns non-zero.
fm_branch_pr_is_merged() {
  local repo=$1 branch=$2 pr_url=$3 candidate=$4 target view state head
  if [ -n "$pr_url" ]; then
    target=$pr_url
  else
    target=$(fm_branch_pr_number_from_branch "$repo" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$repo" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in MERGED|merged) ;; *) return 1 ;; esac
  [ -n "$head" ] || return 1
  fm_branch_ensure_commit_object "$repo" "$target" "$head" || return 1
  git -C "$repo" merge-base --is-ancestor "$candidate" "$head" 2>/dev/null && return 0
  fm_branch_unpushed_patches_are_in_pr_head "$repo" "$candidate" "$head"
}

# fm_branch_content_in_default <repo> <candidate>: the exact content proof
# formerly owned inline by teardown, generalized from HEAD to a candidate ref.
fm_branch_content_in_default() {
  local repo=$1 candidate=$2 name ref default_tree merged_tree
  name=$(fm_branch_default_branch "$repo") || return 1
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$repo" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$repo" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$repo" merge-tree --write-tree "$ref" "$candidate" 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# fm_branch_work_is_landed <repo> <branch> <pr-url-or-empty> <candidate>:
# the shared GitHub-aware/content landedness proof. This is the one owner used
# by teardown and the on-demand full sweep.
fm_branch_work_is_landed() {
  local repo=$1 branch=$2 pr_url=$3 candidate=$4
  git -C "$repo" cat-file -e "$candidate^{commit}" 2>/dev/null || return 1
  fm_branch_pr_is_merged "$repo" "$branch" "$pr_url" "$candidate" && return 0
  fm_branch_content_in_default "$repo" "$candidate"
}
