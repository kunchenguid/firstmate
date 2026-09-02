#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward unless the captain explicitly
# takes the --drop-local-commits escape hatch below - otherwise it refuses any
# landing that would drop a local commit and names every one of them. See
# AGENTS.md prime directives, project management, and task lifecycle.
#
# The local-commit guard exists because a task worktree is always freshened from
# origin's default-branch tip, never from the local default branch. On a project
# whose local default branch carries commits origin does not have (a fork that
# cannot merge upstream, or local adoptions of unmerged upstream work), a branch
# cut from that fresh base does not contain them, so landing it naively would
# erase them. The guard names those commits and the reconciliation that keeps
# them: `git merge <default>` inside the task branch.
#
# --drop-local-commits is the deliberate escape hatch for the case where losing
# them IS the intent. It is never the default and never silent: when the guard
# did not trigger it drops nothing and says so rather than passing as a silent
# no-op, and when it did it prints every dropped commit, pins the pre-reset tip
# of the default branch under refs/fm-dropped/<id>/<short-sha> and records them
# in state/<id>.local-merge-drop before touching the branch, and then resets the
# default branch to the task branch. That rescue ref is what makes the
# recorded SHAs recoverable: after the reset the dropped commits hang off nothing
# else, and the reflog that would otherwise hold them expires
# (gc.reflogExpireUnreachable, 30 days by default) and is then pruned by `git gc`.
# A ref never expires, so the commits stay in the project for as long as it does.
# The ref is keyed by the rescued tip, not by the task, so a later drop on the
# same task plants its own ref beside the earlier one instead of displacing it,
# and the branch never moves when a ref cannot be planted. The branch move is a
# compare-and-swap against the inspected default tip, so a concurrent newer tip
# is preserved; a newly planted rescue is removed again when that compare-and-swap
# refuses, while a rescue from an earlier completed drop remains intact. Checkout
# synchronization also refuses concurrent index or worktree changes instead of
# overwriting them. Each ref is released on its own
# - `git update-ref -d refs/fm-dropped/<id>/<short-sha>` frees exactly
# that drop's commits and leaves every other rescue alone - which is the
# deliberate counterpart of the guarantee: until then those commits stay in the
# project. Being destructive, the whole escape hatch needs the captain's explicit
# word.
# Usage: fm-merge-local.sh [--drop-local-commits] <task-id>
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

DROP_LOCAL=no
ID=
while [ $# -gt 0 ]; do
  case "$1" in
    --drop-local-commits) DROP_LOCAL=yes ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option '$1'; usage: fm-merge-local.sh [--drop-local-commits] <task-id>" >&2; exit 1 ;;
    *)
      [ -z "$ID" ] || { echo "error: unexpected argument '$1'; usage: fm-merge-local.sh [--drop-local-commits] <task-id>" >&2; exit 1; }
      ID=$1
      ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "usage: fm-merge-local.sh [--drop-local-commits] <task-id>" >&2; exit 1; }

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

# Commits on the local default branch that the task branch does not contain.
# Empty means the merge is a clean fast-forward and nothing local is dropped;
# non-empty is exactly the trap this guard exists for.
DROPPED=$(git -C "$PROJ" rev-list "$BRANCH..$DEFAULT")

if [ -n "$DROPPED" ]; then
  if [ "$DROP_LOCAL" != yes ]; then
    {
      echo "REFUSED: landing $BRANCH would drop $(printf '%s\n' "$DROPPED" | wc -l | tr -d ' ') commit(s) that exist only on local $DEFAULT:"
      git -C "$PROJ" log --no-decorate --format='  %h %s' "$BRANCH..$DEFAULT"
      echo "$BRANCH was cut from origin/$DEFAULT, so it never contained them."
      echo "Reconcile first: run 'git merge $DEFAULT' inside $BRANCH (in its own worktree), resolve any conflicts, then retry this merge."
      echo "If dropping those commits is genuinely intended, re-run with --drop-local-commits (destructive; needs the captain's explicit word)."
    } >&2
    exit 1
  fi

  before=$(git -C "$PROJ" rev-parse "$DEFAULT")
  target=$(git -C "$PROJ" rev-parse "$BRANCH")
  RECORD="$STATE/$ID.local-merge-drop"
  # Keyed by the rescued tip, so successive drops on one task never contend for
  # the same name and none can displace another's commits.
  RESCUE_REF="refs/fm-dropped/$ID/$(git -C "$PROJ" rev-parse --short "$before")"

  # Plant it BEFORE the reset, and never move the branch without it: it is the
  # only thing that keeps the dropped commits reachable once the reflog is
  # pruned. Creating it with an empty expected value makes clobbering impossible.
  rescue_created=no
  held=$(git -C "$PROJ" rev-parse --verify --quiet "$RESCUE_REF^{commit}" || true)
  if [ "$held" = "$before" ]; then
    echo "note: rescue ref $RESCUE_REF already holds $before from an earlier drop; leaving it as it is"
  else
    git -C "$PROJ" update-ref "$RESCUE_REF" "$before" "" || {
      echo "error: could not plant rescue ref $RESCUE_REF at $before in $PROJ; refusing to drop commits with no way back. $DEFAULT is untouched." >&2
      exit 1
    }
    rescue_created=yes
  fi

  attempt="$(date -u '+%Y-%m-%dT%H:%M:%SZ').${BASHPID:-$$}"
  {
    echo "# $attempt fm-merge-local.sh --drop-local-commits"
    echo "attempt=$attempt"
    echo "status=pending"
    echo "task=$ID"
    echo "project=$PROJ"
    echo "default=$DEFAULT"
    echo "branch=$BRANCH"
    echo "default_before=$before"
    echo "rescue_ref=$RESCUE_REF"
    for sha in $DROPPED; do
      git -C "$PROJ" log -1 --no-decorate --format='pending=%H %s' "$sha"
    done
  } >> "$RECORD"

  if ! git -C "$PROJ" update-ref "refs/heads/$DEFAULT" "$target" "$before"; then
    current=$(git -C "$PROJ" rev-parse "refs/heads/$DEFAULT")
    rescue_released=not-created
    if [ "$rescue_created" = yes ]; then
      if git -C "$PROJ" update-ref -d "$RESCUE_REF" "$before"; then
        rescue_released=yes
      else
        rescue_released=failed
      fi
    fi
    {
      echo "attempt=$attempt"
      echo "status=failed"
      echo "default_current=$current"
      echo "rescue_ref_released=$rescue_released"
    } >> "$RECORD"
    if [ "$rescue_released" = failed ]; then
      echo "warning: could not release newly planted rescue ref $RESCUE_REF; inspect it before cleanup" >&2
    fi
    echo "error: local $DEFAULT advanced concurrently from $before to $current; preserved the newer tip and refused to overwrite it without touching the checkout" >&2
    exit 1
  fi
  {
    echo "attempt=$attempt"
    echo "status=completed"
    for sha in $DROPPED; do
      git -C "$PROJ" log -1 --no-decorate --format='dropped=%H %s' "$sha"
    done
  } >> "$RECORD"
  if ! git -C "$PROJ" read-tree -m -u "$before" "$target"; then
    {
      echo "attempt=$attempt"
      echo "status=sync-failed"
      echo "default_current=$(git -C "$PROJ" rev-parse "refs/heads/$DEFAULT")"
    } >> "$RECORD"
    echo "error: landed $BRANCH without overwriting $DEFAULT, but concurrent index or worktree changes prevented safe checkout synchronization and were left untouched" >&2
    exit 1
  fi

  echo "DROPPING $(printf '%s\n' "$DROPPED" | wc -l | tr -d ' ') local-only commit(s) from $DEFAULT as explicitly authorized:"
  for sha in $DROPPED; do
    git -C "$PROJ" log -1 --no-decorate --format='  %H %s' "$sha"
  done
  echo "recorded in $RECORD; rescue ref $RESCUE_REF now holds $DEFAULT's pre-reset tip, so those commits stay in $PROJ (not just in the reflog) and stay recoverable by full SHA"
  echo "release this drop's commits for good with: git -C $PROJ update-ref -d $RESCUE_REF (other drops keep their own ref)"
  after=$(git -C "$PROJ" rev-parse --short "refs/heads/$DEFAULT")
  echo "reset local $DEFAULT to $BRANCH ($(git -C "$PROJ" rev-parse --short "$before") -> $after) in $PROJ"
  exit 0
fi

if [ "$DROP_LOCAL" = yes ]; then
  echo "note: --drop-local-commits was unnecessary; $BRANCH already contains every local $DEFAULT commit"
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
