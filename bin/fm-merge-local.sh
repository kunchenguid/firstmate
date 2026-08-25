#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - the default branch itself is
# never rewritten, rebased, or forced.
# A branch that diverged from the default because a parallel lane landed first
# gets ONE automatic trivial rebase in a throwaway detached worktree before the
# fast-forward: when its commits replay cleanly onto the current default tip,
# the lane lands without a worker roundtrip. A real conflict refuses loudly,
# names the conflicted files, and leaves both branches untouched - that roundtrip
# belongs to the worker. The crewmate branch ref and its worktree are never
# modified. See AGENTS.md prime directives, project management, and task
# lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

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

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Attempt a conflict-free rebase of BRANCH onto base commit $2 inside a
# throwaway detached worktree, so the landing itself stays a clean fast-forward.
# Prints the rebased tip sha on stdout. On a real merge conflict prints a loud
# REFUSED block naming the conflicted files and returns 1. Never forces, never
# rewrites the default branch, never touches the crewmate branch or its worktree.
rebase_branch_onto() {  # <branch> <base-commit>
  local branch=$1 base=$2 tmpwt conflicts tip
  tmpwt=$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-local-rebase.XXXXXX") || {
    echo "error: could not create a throwaway worktree directory to rebase $branch; refusing to land non-fast-forward" >&2
    return 1
  }
  if ! git -C "$PROJ" worktree add --quiet --detach "$tmpwt" "$branch"; then
    rmdir "$tmpwt" 2>/dev/null || true
    echo "error: could not create a throwaway worktree to rebase $branch onto the current $DEFAULT; refusing to land non-fast-forward" >&2
    return 1
  fi
  tip=""
  if git -C "$tmpwt" rebase --empty=drop --quiet "$base"; then
    tip=$(git -C "$tmpwt" rev-parse HEAD)
  else
    conflicts=$(git -C "$tmpwt" diff --name-only --diff-filter=U 2>/dev/null | head -20)
    git -C "$tmpwt" rebase --abort >/dev/null 2>&1 || true
    echo "REFUSED: automatic trivial rebase of $branch onto the current $DEFAULT hit real conflicts:" >&2
    if [ -n "$conflicts" ]; then
      while IFS= read -r f; do printf '  %s\n' "$f" >&2; done <<<"$conflicts"
    else
      echo "  (git reported no per-file conflict paths)" >&2
    fi
    echo "Nothing was merged: local $DEFAULT is unchanged at $(git -C "$PROJ" rev-parse --short "$DEFAULT"). Have the worker rebase and resolve, then retry." >&2
  fi
  if ! git -C "$PROJ" worktree remove --force "$tmpwt" >/dev/null 2>&1; then
    rm -rf "$tmpwt"
    git -C "$PROJ" worktree prune >/dev/null 2>&1 || true
  fi
  [ -n "$tip" ] || return 1
  if ! git -C "$PROJ" merge-base --is-ancestor "$base" "$tip"; then
    echo "error: rebased result is not on top of the current $DEFAULT; refusing to land it" >&2
    return 1
  fi
  printf '%s\n' "$tip"
}

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
landed_via_rebase=""
if git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
else
  # Parallel lanes can finish out of order: an earlier landing makes this branch
  # non-fast-forward even though its diff is disjoint. Replay its commits onto
  # the current default tip here instead of paying a worker roundtrip, retrying
  # in bounds when another lane lands during the rebase.
  attempts=${FM_MERGE_LOCAL_REBASE_ATTEMPTS:-3}
  case "$attempts" in ''|*[!0-9]*) attempts=3 ;; esac
  while :; do
    base_commit=$(git -C "$PROJ" rev-parse --verify "${DEFAULT}^{commit}")
    tip_commit=$(rebase_branch_onto "$BRANCH" "$base_commit") || exit 1
    now_commit=$(git -C "$PROJ" rev-parse --verify "${DEFAULT}^{commit}")
    if [ "$now_commit" != "$base_commit" ]; then
      attempts=$((attempts - 1))
      if [ "$attempts" -le 0 ]; then
        echo "REFUSED: local $DEFAULT kept advancing while rebasing (concurrent landings); nothing was merged. Let the lanes settle, then retry." >&2
        exit 1
      fi
      echo "note: $DEFAULT advanced while rebasing; retrying the trivial rebase on the new tip" >&2
      continue
    fi
    break
  done
  if [ "$tip_commit" = "$base_commit" ]; then
    echo "nothing to land: $BRANCH content is already contained in local $DEFAULT ($before); no merge performed"
    exit 0
  fi
  git -C "$PROJ" merge --ff-only "$tip_commit" >/dev/null
  landed_via_rebase=" (after automatic trivial rebase)"
fi
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ$landed_via_rebase"
