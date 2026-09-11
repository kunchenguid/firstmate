#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's ready branch, discovered from the
# task worktree's checked-out HEAD (any branch name, per the convention owned by
# bin/fm-brief.sh). --branch <name> recovers the case where the worktree cannot
# report its branch (missing worktree=, pruned, or detached HEAD); a readable HEAD
# stays authoritative and a disagreeing --branch is refused, so only the task's own
# work lands. Every merge guard below still applies.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# Usage: fm-merge-local.sh <task-id> [--branch <name>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
shift
BRANCH_OVERRIDE=
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      BRANCH_OVERRIDE=${2:-}
      [ -n "$BRANCH_OVERRIDE" ] || { echo "error: --branch needs a branch name" >&2; exit 2; }
      shift 2
      ;;
    --branch=*)
      BRANCH_OVERRIDE=${1#--branch=}
      [ -n "$BRANCH_OVERRIDE" ] || { echo "error: --branch needs a branch name" >&2; exit 2; }
      shift
      ;;
    *)
      echo "error: invalid local merge request" >&2
      exit 2
      ;;
  esac
done
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This precedes reading the task
# record, because the wrong actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
WT=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
# Validate the project before any git -C "$PROJ": an empty value would silently
# retarget every command below at the current directory, which is firstmate's
# own primary checkout.
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

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

# The worktree HEAD is the source of truth (it ties the branch to THIS task);
# --branch is only a fallback for when the worktree cannot answer.
DISCOVERED=
why=
if [ -z "$WT" ]; then
  why="meta for task $ID is missing worktree="
elif [ ! -d "$WT" ]; then
  why="worktree for task $ID is missing: $WT"
else
  DISCOVERED=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$DISCOVERED" ] || why="worktree $WT for task $ID is detached"
fi

if [ -n "$DISCOVERED" ]; then
  # A readable HEAD outranks the override. Disagreement means the caller named a
  # branch that is not this task's checked-out work, so refuse instead of landing it.
  if [ -n "$BRANCH_OVERRIDE" ] && [ "$BRANCH_OVERRIDE" != "$DISCOVERED" ]; then
    echo "REFUSED: --branch $BRANCH_OVERRIDE disagrees with the branch task $ID has checked out ($DISCOVERED)." >&2
    echo "--branch only recovers a worktree that cannot report its branch; it never selects a different one." >&2
    echo "Merge $DISCOVERED by rerunning without --branch, or resolve the mismatch in $WT first." >&2
    exit 1
  fi
  BRANCH=$DISCOVERED
else
  BRANCH=$BRANCH_OVERRIDE
  [ -n "$BRANCH" ] || {
    echo "error: $why; cannot determine the ready branch" >&2
    echo "Pass the branch the crewmate reported ready: bin/fm-merge-local.sh $ID --branch <name>" >&2
    exit 1
  }
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# Merging the default into itself is a no-op that would report success as if work
# landed; require a real task branch (matters most on the operator-supplied --branch).
[ "$BRANCH" != "$DEFAULT" ] || { echo "error: ready branch is the default branch '$DEFAULT'; there is nothing to merge" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# A no-op fast-forward (default already contained the branch) landed nothing;
# report it as a failure rather than a successful merge.
[ "$before" != "$after" ] || { echo "error: no-op merge of $BRANCH into $DEFAULT ($before unchanged); nothing landed" >&2; exit 1; }
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
