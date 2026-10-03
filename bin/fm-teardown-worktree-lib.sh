#!/usr/bin/env bash
# Shared copy-preservation checks for fm-teardown.sh. No source-time effects.
# Completed retirement retains a copy on refusal and still closes its endpoint;
# the ordinary teardown path refuses the whole destructive transaction.
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3

# Resolve Treehouse's exact managed spelling for an existing directory.
# `test -ef` compares the followed directory device and inode, so it accepts both
# symlink-prefix and bind-mount aliases without accepting lexical resemblance.
# The public status/enter interface exists in the pinned Treehouse 2.0.1 build.
TREEHOUSE_MANAGED_RETURN_PATH=
treehouse_managed_return_path_for_identity() {  # <recorded-dir> <project-dir> [include-recorded: 0|1]
  local dir=$1 cd_dir=$2 include_recorded=${3:-0} status line name candidate matches=0 matched=
  TREEHOUSE_MANAGED_RETURN_PATH=
  [ -d "$dir" ] || return 1
  status=$( ( cd "$cd_dir" && treehouse status ) 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      ''|[[:space:]]*) continue ;;
    esac
    name=${line%%[[:space:]]*}
    case "$name" in
      ''|*[!A-Za-z0-9._-]*) continue ;;
    esac
    candidate=$( ( cd "$cd_dir" && treehouse enter --print-path "$name" ) 2>/dev/null) || continue
    case "$candidate" in
      /*) ;;
      *) continue ;;
    esac
    case "$candidate" in
      *$'\n'*|*$'\r'*|*$'\t'*) continue ;;
    esac
    [ "$include_recorded" = 1 ] || [ "$candidate" != "$dir" ] || continue
    [ -d "$candidate" ] || continue
    if [ "$candidate" -ef "$dir" ]; then
      matches=$((matches + 1))
      matched=$candidate
    fi
  done <<EOF
$status
EOF
  [ "$matches" -eq 1 ] || return 1
  TREEHOUSE_MANAGED_RETURN_PATH=$matched
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
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

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state remainder head resolved_url current landed=0
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif unpushed_patches_are_in_pr_head "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -z "$PR_URL" ]; then
    [ -n "$resolved_url" ] || return 1
    PR_URL=$resolved_url
  fi
  return 0
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  [ -d "$WT" ] || return 0
  if [ "${1:-}" != completed ]; then
    [ "$FORCE" != "--force" ] || return 0
    [ "$KIND" != scout ] || return 0
  fi

  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | head -1 || true)

  if [ "${1:-}" = completed ]; then
    [ -z "$dirty" ] || return 1
    # A pushed feature branch alone is not integration into the default branch.
    # Reuse the current content-in-default proof without a forge/UI gate.
    content_in_default && return 0
    echo "retaining completed copy $WT: content is not proved integrated into the default branch" >&2
    return 1
  fi

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

# One completed-copy owner for initial retirement and the exact later copy-only
# retry. The caller holds the task lock, has bound copy identity in the existing
# cleanup receipt, and records phase postconditions through the endpoint receipt
# owner. No endpoint, process, backlog, metadata or business effects occur here.
teardown_completed_copy() { # <canonical-copy> <project> <generation>
  local copy=$1 project=$2 generation=$3 candidate other field dirty copy_readback managed_copy=$1
  # shellcheck source=bin/fm-cleanup-receipt-lib.sh
  . "$SCRIPT_DIR/fm-cleanup-receipt-lib.sh"
  copy_readback=$(fm_cleanup_receipt copy-read "$ID" "$generation") || return 1
  if [ "$(printf '%s' "$copy_readback" | jq -r '.phase.state')" = pending ]; then
    echo 'REFUSED: copy disposal may have happened; exact effect readback required' >&2; return 1
  fi
  COPY_DISPOSITION=returned-or-already-absent
  COPY_REASON="copy-already-absent"
  [ -d "$copy" ] || return 0
  COPY_DISPOSITION=retained-unverified
  COPY_REASON="project-lock-unavailable"
  copy_lock=$(fm_treehouse_project_lock_path "$project") || return 0
  if fm_lock_try_acquire "$copy_lock"; then copy_lock_held=1
  else COPY_REASON="project-lock-busy"; return 0
  fi
  for candidate in "$project" "$FM_HOME" "$FM_ROOT"; do
    [ -d "$candidate" ] || continue
    candidate=$(cd "$candidate" && pwd -P) || return 0
    case "$candidate/" in "$copy/"*) COPY_DISPOSITION=retained-primary; COPY_REASON="primary-checkout"; return 0 ;; esac
  done
  candidate=$(git -C "$copy" rev-parse --show-toplevel 2>/dev/null) || candidate=
  if [ -d "$candidate" ] && [ ! "$candidate" -ef "$copy" ]; then
    COPY_DISPOSITION=retained-primary; COPY_REASON="primary-checkout-subdirectory"; return 0
  fi
  for other in "$STATE"/*.meta; do
    [ "$other" != "$STATE/$ID.meta" ] && [ -f "$other" ] && [ ! -L "$other" ] || continue
    for field in worktree home; do
      candidate=$(fm_meta_get "$other" "$field")
      if [ -d "$candidate" ] && [ "$candidate" -ef "$copy" ]; then
        COPY_DISPOSITION=retained-shared; COPY_REASON="another-task-record"; return 0
      fi
    done
  done
  if fm_treehouse_pool_slot "$project" "$copy"; then
    fm_treehouse_slot_owner_state "$copy" "$ID" "$generation"
    if [ "$FM_TREEHOUSE_SLOT_OWNER" = other ] || \
       { [ -n "$FM_TREEHOUSE_SLOT_OWNER_HOME" ] && [ "$FM_TREEHOUSE_SLOT_OWNER_HOME" != "$FM_HOME" ]; }; then
      COPY_DISPOSITION=retained-shared; COPY_REASON="pool-slot-claimed-elsewhere"; return 0
    elif [ "$FM_TREEHOUSE_SLOT_OWNER" != mine ] || [ -z "$generation" ] || \
         [ "$FM_TREEHOUSE_SLOT_OWNER_HOME" != "$FM_HOME" ]; then
      COPY_REASON="pool-slot-owner-unproved"; return 0
    fi
  fi
  WT=$copy
  PROJ=$project
  COPY_REASON="original-git-owner-unproved"
  printf '%s' "$copy_readback" | jq -e '.binding.copy.git!=null and .binding.project.git!=null' >/dev/null || return 0
  COPY_REASON="git-status-unreadable"
  dirty=$(git -C "$copy" status --porcelain 2>/dev/null) || return 0
  if [ -n "$dirty" ]; then COPY_DISPOSITION=retained-dirty; COPY_REASON="uncommitted-content"; return 0; fi
  if ! validate_worktree_teardown_safety completed; then
    COPY_DISPOSITION=retained-unlanded; COPY_REASON="content-not-proved-in-default"; return 0
  fi
  if fm_treehouse_pool_slot "$project" "$copy"; then
    COPY_REASON="treehouse-managed-path-unproved"
    treehouse_managed_return_path_for_identity "$copy" "$project" 1 || return 0
    managed_copy=$TREEHOUSE_MANAGED_RETURN_PATH
  fi
  # Revalidate inode/path identity immediately before the first disposal effect.
  fm_cleanup_receipt copy-read "$ID" "$generation" >/dev/null || { COPY_REASON="copy-identity-changed"; return 0; }
  teardown_endpoint_receipt directory_return pending copy-disposal-attempt || return 1
  COPY_REASON="copy-disposal-uncertain"
  if fm_treehouse_pool_slot "$project" "$copy"; then
    if (cd "$project" && treehouse return --force "$managed_copy"); then
      fm_treehouse_slot_owner_release "$copy" "$ID" "$generation"
    else return 1
    fi
  elif git -C "$project" worktree list --porcelain | sed -n 's/^worktree //p' | grep -Fxq "$copy"; then
    git -C "$project" worktree remove --force "$copy" || return 1
  else
    rm -rf -- "$copy" || return 1
    [ ! -e "$copy" ] && [ ! -L "$copy" ] || return 1
  fi
  COPY_DISPOSITION=returned-or-already-absent
  COPY_REASON="copy-disposal-confirmed"
}
