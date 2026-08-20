#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task, in two guarded
# stages: fast-forward the project clone's default branch to the crewmate's
# fm/<id> branch, then carry that same default branch into the folder the clone
# names as its origin, so the landing reaches the copy its owner actually reads.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# Stage two exists because a local-only project's canonical copy is a folder
# outside projects/, and a change that stops in the clone is invisible there. Git
# refuses a push into a non-bare repository's checked-out branch, so the landing
# pulls from the clone into that folder instead. It is as narrow as stage one and
# never forces, stashes, or discards: it runs only when origin names a git work
# tree on this machine, only while that folder sits on the same default branch,
# only as a fast-forward, and only when nothing uncommitted there touches a path
# the fast-forward would change. Anything else refuses with the concrete reason.
# An origin that is absent, a bare repository, or a URL on another host is not a
# folder anyone reads, so the landing simply reports that it ended at the clone.
# Both stages are idempotent, so a repeat run converges instead of refusing.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
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

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

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
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# Stage two: carry the landed default branch into the folder this clone calls
# origin. Everything below either completes that carry or refuses it out loud;
# nothing here is allowed to reach for a fallback.
PROJ_ABS=$(cd "$PROJ" && pwd -P)
ORIGIN_URL=$(git -C "$PROJ" remote get-url origin 2>/dev/null || true)
if [ -z "$ORIGIN_URL" ]; then
  echo "landing ended in $PROJ: it has no origin, so this clone is the project's only copy"
  exit 0
fi
if ! ORIGIN_PATH=$(fm_project_origin_local_path "$ORIGIN_URL"); then
  echo "landing ended in $PROJ: origin $ORIGIN_URL is not a folder on this machine"
  exit 0
fi
if [ ! -d "$ORIGIN_PATH" ]; then
  echo "REFUSED: origin $ORIGIN_PATH is missing, so the landing cannot reach the project's own folder." >&2
  echo "The change is safe in $PROJ on $DEFAULT; restore or re-point that origin, then retry." >&2
  exit 1
fi
if [ "$(git -C "$ORIGIN_PATH" rev-parse --is-bare-repository 2>/dev/null || echo unknown)" = true ]; then
  echo "landing ended in $PROJ: origin $ORIGIN_PATH is a bare repository with no working copy to update"
  exit 0
fi
# git happily answers for an enclosing repository, so require origin to be the
# work-tree ROOT. Otherwise an origin pointing at some directory that merely sits
# inside a repository would land this change in that unrelated repository.
origin_top=$(git -C "$ORIGIN_PATH" rev-parse --show-toplevel 2>/dev/null || true)
origin_real=$(cd "$ORIGIN_PATH" 2>/dev/null && pwd -P) || origin_real=
if [ -n "$origin_top" ]; then
  origin_top=$(cd "$origin_top" 2>/dev/null && pwd -P) || origin_top=
fi
if [ -z "$origin_top" ] || [ -z "$origin_real" ] || [ "$origin_top" != "$origin_real" ]; then
  echo "REFUSED: origin $ORIGIN_PATH is not the root of a git work tree, so the landing cannot reach the project's own folder." >&2
  echo "The change is safe in $PROJ on $DEFAULT; correct that origin, then retry." >&2
  exit 1
fi
ORIGIN_PATH=$origin_real

origin_branch=$(git -C "$ORIGIN_PATH" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$origin_branch" != "$DEFAULT" ]; then
  echo "REFUSED: $ORIGIN_PATH is on '${origin_branch:-a detached HEAD}', not '$DEFAULT'; refusing to change what it has checked out." >&2
  echo "The change is safe in $PROJ on $DEFAULT; switch that folder back to $DEFAULT, then retry." >&2
  exit 1
fi

# Fetch first so both commits are readable in the folder itself, then decide
# there. Fetching writes only objects and FETCH_HEAD, never the working copy.
if ! git -C "$ORIGIN_PATH" fetch --quiet "$PROJ_ABS" "refs/heads/$DEFAULT"; then
  echo "REFUSED: could not read $DEFAULT from $PROJ into $ORIGIN_PATH." >&2
  echo "The change is safe in $PROJ on $DEFAULT; nothing in $ORIGIN_PATH was changed." >&2
  exit 1
fi
target=$(git -C "$ORIGIN_PATH" rev-parse --verify --quiet 'FETCH_HEAD^{commit}') || {
  echo "REFUSED: $PROJ did not yield a commit for $DEFAULT; nothing in $ORIGIN_PATH was changed." >&2
  exit 1
}
current=$(git -C "$ORIGIN_PATH" rev-parse --verify --quiet "refs/heads/$DEFAULT^{commit}") || {
  echo "REFUSED: $ORIGIN_PATH has no $DEFAULT branch to fast-forward." >&2
  echo "The change is safe in $PROJ on $DEFAULT; nothing in $ORIGIN_PATH was changed." >&2
  exit 1
}
if [ "$current" = "$target" ]; then
  echo "already current: $ORIGIN_PATH is on $DEFAULT at $(git -C "$ORIGIN_PATH" rev-parse --short HEAD)"
  exit 0
fi
if ! git -C "$ORIGIN_PATH" merge-base --is-ancestor "$current" "$target"; then
  echo "REFUSED: $ORIGIN_PATH has commits on $DEFAULT that $PROJ does not, so this is not a fast-forward." >&2
  echo "The change is safe in $PROJ on $DEFAULT; reconcile those commits into $PROJ first, then retry." >&2
  exit 1
fi

# A folder someone works in is normally dirty, and that alone is harmless: a
# fast-forward only disturbs uncommitted work when it touches the same paths.
# Ask git which paths those are rather than guessing, and refuse naming them.
CHANGED=()
while IFS= read -r -d '' changed_path; do
  CHANGED+=("$changed_path")
done < <(git -C "$ORIGIN_PATH" diff --name-only --no-renames -z "$current" "$target")
if [ "${#CHANGED[@]}" -gt 0 ]; then
  collisions=$(GIT_LITERAL_PATHSPECS=1 git -C "$ORIGIN_PATH" status --porcelain --untracked-files=all -- "${CHANGED[@]}")
  if [ -n "$collisions" ]; then
    echo "REFUSED: $ORIGIN_PATH has uncommitted work on paths this landing would change:" >&2
    printf '%s\n' "$collisions" >&2
    echo "The change is safe in $PROJ on $DEFAULT; commit, move, or revert those paths yourself, then retry." >&2
    exit 1
  fi
fi

# git's own two-tree safety is the last word: an ff-only merge it declines
# changes nothing, so a refusal here is reported rather than worked around.
if ! merge_output=$(git -C "$ORIGIN_PATH" merge --ff-only --quiet "$target" 2>&1); then
  echo "REFUSED: git declined to fast-forward $ORIGIN_PATH and left it unchanged:" >&2
  printf '%s\n' "$merge_output" >&2
  echo "The change is safe in $PROJ on $DEFAULT." >&2
  exit 1
fi
landed=$(git -C "$ORIGIN_PATH" rev-parse --verify "refs/heads/$DEFAULT^{commit}")
if [ "$landed" != "$target" ]; then
  echo "REFUSED: $ORIGIN_PATH is at $landed on $DEFAULT, not the landed $target." >&2
  exit 1
fi
echo "carried $DEFAULT into $ORIGIN_PATH ($(git -C "$ORIGIN_PATH" rev-parse --short "$current") -> $(git -C "$ORIGIN_PATH" rev-parse --short "$target"))"
