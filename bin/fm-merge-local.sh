#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch - or the task's recorded base= branch (a ship task
# dispatched with fm-spawn.sh --base) - to the crewmate's fm/<id> branch.
# Absent base= keeps today's default-branch behavior; the same safety refusals
# (checkout on the target branch and clean, ff-only, rebase advice on
# divergence) apply to whichever branch is the target.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
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

# The task's recorded base= is the single source of truth for a non-default
# merge target; absent base= falls back to the default branch as before.
BASE_BRANCH=$(grep '^base=' "$META" | cut -d= -f2- || true)
if [ -n "$BASE_BRANCH" ]; then
  TARGET=$BASE_BRANCH
  TARGET_DESC="base branch"
  git -C "$PROJ" show-ref --verify --quiet "refs/heads/$TARGET" || { echo "error: recorded base branch '$TARGET' does not exist in $PROJ" >&2; exit 1; }
else
  TARGET=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
  TARGET_DESC="default branch"
fi

# The project's main checkout must be on the merge target branch and clean, so
# the fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$TARGET" ] || { echo "error: $PROJ is on '$cur', expected $TARGET_DESC '$TARGET'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: TARGET must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$TARGET" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $TARGET (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $TARGET, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$TARGET")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$TARGET")
echo "merged $BRANCH into local $TARGET ($before -> $after) in $PROJ"
