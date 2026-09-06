#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only for a clean recorded SHIP worktree whose HEAD is the
# exact fm/<id> branch tip. It then requires a clean primary default branch and a
# clean fast-forward - it refuses a diverged branch and tells you to have the
# crewmate rebase. See AGENTS.md prime directives, project management, and task
# lifecycle.
#
# Why the task worktree is inspected at all: the branch ref alone cannot tell a
# finished ship from one whose last edits were never committed. Landing on the
# ref would silently publish an older tip while the real work sat uncommitted in
# the isolated copy, and cleanup would then refuse it as unlanded. Every refusal
# below therefore runs BEFORE local main moves.
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
WT=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
[ "$KIND" = ship ] || { echo "error: task $ID is kind=$KIND, not a ship; refusing local merge" >&2; exit 1; }

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

# The shared object store a checkout belongs to: two paths with the same value
# are worktrees of one repository, so a same-named branch elsewhere is not this
# task's evidence.
common_git_dir() {
  local d
  d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  (cd "$d" && pwd -P)
}

# The recorded task worktree is the readiness evidence. Refuse if it cannot be
# inspected as a distinct root of this project's repository, is not on the
# expected branch, has moved off the shared branch ref, or still holds work
# firstmate did not write itself.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  echo "error: task $ID has no inspectable recorded worktree at ${WT:-<missing>}" >&2
  echo "Restore that worktree on $BRANCH (or point the task meta's worktree= at the checkout that holds it), then retry." >&2
  exit 1
fi
WT_REAL=$(cd "$WT" && pwd -P) || { echo "error: cannot resolve task worktree $WT" >&2; exit 1; }
PROJ_REAL=$(cd "$PROJ" && pwd -P) || { echo "error: cannot resolve project $PROJ" >&2; exit 1; }
WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$WT_TOP" ] || { echo "error: recorded worktree $WT is not an inspectable git worktree" >&2; exit 1; }
WT_TOP_REAL=$(cd "$WT_TOP" && pwd -P) || { echo "error: cannot resolve recorded worktree root $WT_TOP" >&2; exit 1; }
WT_COMMON=$(common_git_dir "$WT" || true)
PROJ_COMMON=$(common_git_dir "$PROJ" || true)
if [ "$WT_REAL" != "$WT_TOP_REAL" ] || [ "$WT_REAL" = "$PROJ_REAL" ] \
  || [ -z "$WT_COMMON" ] || [ "$WT_COMMON" != "$PROJ_COMMON" ]; then
  echo "error: recorded worktree $WT is not an isolated task worktree for $PROJ" >&2
  exit 1
fi

wt_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$wt_branch" = "$BRANCH" ] || { echo "error: task worktree is on '${wt_branch:-detached}', expected '$BRANCH'" >&2; exit 1; }
wt_head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
branch_head=$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH" 2>/dev/null || true)
if [ -z "$wt_head" ] || [ -z "$branch_head" ] || [ "$wt_head" != "$branch_head" ]; then
  echo "error: task worktree HEAD does not match refs/heads/$BRANCH; refusing to merge an unverified tip" >&2
  exit 1
fi
if ! task_status=$(git -C "$WT" status --porcelain 2>/dev/null); then
  echo "error: cannot inspect task worktree $WT for uncommitted changes" >&2
  exit 1
fi
# firstmate writes its own harness wiring into the task worktree and only
# best-effort excludes it (bin/fm-spawn.sh), so ignore exactly what the sibling
# gate in bin/fm-teardown.sh ignores; everything else is the crewmate's work.
task_dirt=$(printf '%s\n' "$task_status" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)
if [ -n "$task_dirt" ]; then
  echo "REFUSED: task worktree $WT has uncommitted or untracked changes; local main was not moved" >&2
  exit 1
fi

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of the exact tip the
# readiness checks inspected, not of whatever the mutable branch name resolves
# to by the time this line runs.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$branch_head"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# Every refusal above is evidence about one commit. A worker that advanced
# fm/<id> since then holds work this run never inspected, and neither tip is
# safe to land: the captured one silently publishes an older head, the new one
# is unverified. Refuse instead, and land the captured SHA rather than the
# branch name so the name cannot resolve to something else under us.
now_head=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" 2>/dev/null || true)
if [ "$now_head" != "$branch_head" ]; then
  echo "REFUSED: $BRANCH advanced from $branch_head to ${now_head:-<missing>} while this landing was validating; local $DEFAULT was not moved" >&2
  echo "Re-run this landing once the crewmate has stopped writing to $BRANCH." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$branch_head" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
