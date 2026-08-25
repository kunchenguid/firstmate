#!/usr/bin/env bash
# Sweep a project's firstmate-owned fm/* branches from local refs, GitHub
# origin, and no-mistakes' separate git remote.
#
# bin/fm-branch-merge-lib.sh owns the full proof and exact-tip deletion contract.
# This command enumerates only firstmate-owned fm/* refs across the local repo,
# origin, and no-mistakes, then applies that shared contract to every candidate.
#
# Usage: fm-branch-cleanup.sh <project-dir-or-name>
# A bare name or projects/<name> resolves under $FM_HOME/projects.
# An existing path is used directly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-branch-merge-lib.sh
. "$SCRIPT_DIR/fm-branch-merge-lib.sh"

usage() {
  echo "usage: fm-branch-cleanup.sh <project-dir-or-name>" >&2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || { usage; exit 2; }

resolve_project() {
  local arg=$1 candidate
  if [ -d "$arg" ]; then
    printf '%s\n' "$arg"
    return 0
  fi
  case "$arg" in
    projects/*) candidate="$PROJECTS/${arg#projects/}" ;;
    */*) candidate=$arg ;;
    *) candidate="$PROJECTS/$arg" ;;
  esac
  printf '%s\n' "$candidate"
}

PROJ=$(resolve_project "$1")
[ -d "$PROJ" ] || { echo "branch-cleanup: not a directory: $PROJ" >&2; exit 1; }
git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "branch-cleanup: not a git repo: $PROJ" >&2; exit 1; }
TOPLEVEL=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "branch-cleanup: not a git repo: $PROJ" >&2; exit 1; }
PROJ=$(cd "$PROJ" && pwd -P)
[ "$PROJ" = "$TOPLEVEL" ] \
  || { echo "branch-cleanup: not a git repo root: $PROJ" >&2; exit 1; }

label=$(basename "$PROJ")
cleaned=0

cleanup_remote_candidates() {
  local remote=$1 tip ref branch
  git -C "$PROJ" remote get-url "$remote" >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r tip ref; do
    [ -n "$tip" ] && [ -n "$ref" ] || continue
    branch=${ref#refs/heads/}
    case "$branch" in fm/*) ;; *) continue ;; esac
    fm_branch_worktree_has_branch "$PROJ" "$branch" && continue
    fm_branch_fetch_remote_tip "$PROJ" "$remote" "$branch" "$tip" || continue
    fm_branch_work_is_landed "$PROJ" "$branch" "" "$tip" || continue
    if fm_branch_delete_remote_proven_tip "$PROJ" "$remote" "$branch" "$tip"; then
      echo "$label: pruned $remote/$branch"
      cleaned=$((cleaned + 1))
    fi
  done < <(git -C "$PROJ" ls-remote --heads "$remote" 'refs/heads/fm/*' 2>/dev/null || true)
}

cleanup_matching_remote_tips() {
  local branch=$1 tip=$2 remote remote_tip
  for remote in origin no-mistakes; do
    remote_tip=$(fm_branch_remote_tip "$PROJ" "$remote" "$branch") || continue
    [ "$remote_tip" = "$tip" ] || continue
    if fm_branch_delete_remote_proven_tip "$PROJ" "$remote" "$branch" "$tip"; then
      echo "$label: pruned $remote/$branch"
      cleaned=$((cleaned + 1))
    fi
  done
}

# Remote-only branches have no local ref to carry an ancestor or gone-upstream
# proof, so each exact remote tip passes the shared GitHub-aware/content proof.
cleanup_remote_candidates origin
cleanup_remote_candidates no-mistakes

default=$(fm_branch_default_branch "$PROJ" 2>/dev/null || true)
while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  fm_branch_worktree_has_branch "$PROJ" "$branch" && continue
  tip=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$branch") || continue

  if [ -n "$default" ] \
    && fm_branch_is_safely_merged "$PROJ" "$branch" "refs/heads/$default" "$tip"; then
    cleanup_matching_remote_tips "$branch" "$tip"
    if fm_branch_delete_if_safely_merged "$PROJ" "$branch" "refs/heads/$default"; then
      echo "$label: pruned $branch (merged into $default)"
      cleaned=$((cleaned + 1))
    fi
    continue
  fi

  if fm_branch_is_safely_gone "$PROJ" "$branch" "$tip"; then
    cleanup_matching_remote_tips "$branch" "$tip"
    if fm_branch_delete_if_safely_gone "$PROJ" "$branch"; then
      echo "$label: pruned $branch (upstream gone)"
      cleaned=$((cleaned + 1))
    fi
    continue
  fi

  if fm_branch_work_is_landed "$PROJ" "$branch" "" "$tip"; then
    cleanup_matching_remote_tips "$branch" "$tip"
    if fm_branch_delete_local_proven_tip "$PROJ" "$branch" "$tip"; then
      echo "$label: pruned $branch (landed)"
      cleaned=$((cleaned + 1))
    fi
  fi
done < <(git -C "$PROJ" for-each-ref --format='%(refname:short)' 'refs/heads/fm/*' 2>/dev/null)

[ "$cleaned" -ne 0 ] || echo "$label: no eligible branches"
