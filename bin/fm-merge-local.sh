#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# A main-home task keeps the historical one-argument form.
# A secondmate-owned task stays in that home's state and is selected explicitly:
#   fm-merge-local.sh <task-id> --secondmate <secondmate-id>
# The secondmate path requires the exact ready commit and validation evidence
# recorded by fm-secondmate-report.sh --local-ready, imports only that branch,
# and fast-forwards the main home's authoritative checkout to that exact commit.
# A .fm-secondmate-home marker always refuses this script before any project
# inspection or mutation.
# Usage: fm-merge-local.sh <task-id> [--secondmate <secondmate-id>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() {
  echo "usage: fm-merge-local.sh <task-id> [--secondmate <secondmate-id>]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
ID=$1
shift
SECOND_MATE_ID=
while [ $# -gt 0 ]; do
  case "$1" in
    --secondmate)
      [ $# -ge 2 ] || usage
      SECOND_MATE_ID=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) usage ;;
esac
if [ -n "$SECOND_MATE_ID" ]; then
  case "$SECOND_MATE_ID" in
    ''|.*|*[!A-Za-z0-9._-]*) usage ;;
  esac
fi
if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
  echo "REFUSED: local landing is main-firstmate-only; $FM_HOME is marked as a secondmate home." >&2
  exit 1
fi

meta_get() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

canonical_dir() {
  local dir=$1
  [ -d "$dir" ] || return 1
  cd "$dir" && pwd -P
}

secondmate_home() {
  local id=$1 line home marker
  [ -f "$DATA/secondmates.md" ] || {
    echo "error: no secondmate registry at $DATA/secondmates.md" >&2
    return 1
  }
  line=$(awk -v id="$id" '$1 == "-" && $2 == id { line=$0 } END { print line }' "$DATA/secondmates.md")
  [ -n "$line" ] || {
    echo "error: secondmate $id is not registered in $DATA/secondmates.md" >&2
    return 1
  }
  home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
  [ -n "$home" ] || {
    echo "error: secondmate $id has no home in $DATA/secondmates.md" >&2
    return 1
  }
  home=$(canonical_dir "$home") || {
    echo "error: secondmate home does not exist or is not a directory: $home" >&2
    return 1
  }
  [ -f "$home/.fm-secondmate-home" ] || {
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  }
  marker=$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)
  [ "$marker" = "$id" ] || {
    echo "error: firstmate home $home is marked for secondmate ${marker:-unknown}, expected $id" >&2
    return 1
  }
  printf '%s\n' "$home"
}

"$FM_ROOT/bin/fm-guard.sh" || true
SOURCE_HOME=
if [ -n "$SECOND_MATE_ID" ]; then
  SOURCE_HOME=$(secondmate_home "$SECOND_MATE_ID") || exit 1
  META="$SOURCE_HOME/state/$ID.meta"
else
  META="$STATE/$ID.meta"
fi
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

SOURCE_PROJ=$(meta_get "$META" project)
PROJ=$SOURCE_PROJ
MODE=$(meta_get "$META" mode)
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
READY_COMMIT=
if [ -n "$SECOND_MATE_ID" ]; then
  PROJECT_NAME=$(basename "$SOURCE_PROJ")
  EXPECTED_SOURCE=$(canonical_dir "$SOURCE_HOME/projects/$PROJECT_NAME") || {
    echo "error: secondmate project $PROJECT_NAME is missing under $SOURCE_HOME/projects" >&2
    exit 1
  }
  RESOLVED_SOURCE_PROJ=$(canonical_dir "$SOURCE_PROJ") || {
    echo "error: task $ID project is missing: ${SOURCE_PROJ:-<empty>}" >&2
    exit 1
  }
  SOURCE_PROJ=$RESOLVED_SOURCE_PROJ
  [ "$SOURCE_PROJ" = "$EXPECTED_SOURCE" ] || {
    echo "error: task $ID project $SOURCE_PROJ is not the registered secondmate clone $EXPECTED_SOURCE" >&2
    exit 1
  }
  PROJ=$(canonical_dir "$PROJECTS/$PROJECT_NAME") || {
    echo "error: authoritative project $PROJECT_NAME is missing under $PROJECTS" >&2
    exit 1
  }
  read -r MAIN_MODE _ <<EOF
$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-project-mode.sh" "$PROJECT_NAME")
EOF
  [ "$MAIN_MODE" = local-only ] || {
    echo "error: authoritative project $PROJECT_NAME is mode=$MAIN_MODE, not local-only" >&2
    exit 1
  }

  READY_COMMIT=$(meta_get "$META" ready_commit)
  READY_BRANCH=$(meta_get "$META" ready_branch)
  VALIDATION_EVIDENCE=$(meta_get "$META" validation_evidence)
  printf '%s\n' "$READY_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "error: task $ID has no valid exact ready_commit in $META; route it with bin/fm-secondmate-report.sh --local-ready first" >&2
    exit 1
  }
  [ "$READY_BRANCH" = "$BRANCH" ] || {
    echo "error: task $ID ready branch is ${READY_BRANCH:-missing}, expected $BRANCH" >&2
    exit 1
  }
  [ -n "$VALIDATION_EVIDENCE" ] || {
    echo "error: task $ID has no recorded validation evidence in $META" >&2
    exit 1
  }
  SOURCE_BRANCH_COMMIT=$(git -C "$SOURCE_PROJ" rev-parse --verify "refs/heads/$BRANCH" 2>/dev/null || true)
  [ "$SOURCE_BRANCH_COMMIT" = "$READY_COMMIT" ] || {
    echo "error: ready branch $BRANCH moved after reporting; expected $READY_COMMIT, found ${SOURCE_BRANCH_COMMIT:-missing}" >&2
    exit 1
  }
  WORKTREE=$(meta_get "$META" worktree)
  WORKTREE_BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  WORKTREE_COMMIT=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null || true)
  [ "$WORKTREE_BRANCH" = "$BRANCH" ] && [ "$WORKTREE_COMMIT" = "$READY_COMMIT" ] || {
    echo "error: task $ID worktree no longer matches ready $BRANCH at $READY_COMMIT" >&2
    exit 1
  }
  if ! WORKTREE_STATUS=$(git -C "$WORKTREE" status --porcelain 2>/dev/null); then
    echo "error: cannot inspect ready worktree status for task $ID: $WORKTREE" >&2
    exit 1
  fi
  WORKTREE_DIRTY=$(printf '%s\n' "$WORKTREE_STATUS" \
    | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' \
    | head -1 || true)
  [ -z "$WORKTREE_DIRTY" ] || {
    echo "error: task $ID worktree became dirty after it was reported ready" >&2
    exit 1
  }
else
  RESOLVED_PROJ=$(canonical_dir "$PROJ") || {
    echo "error: task $ID project is missing: ${PROJ:-<empty>}" >&2
    exit 1
  }
  PROJ=$RESOLVED_PROJ
  git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || {
    echo "error: branch $BRANCH does not exist in $PROJ" >&2
    exit 1
  }
fi

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  if [ -n "$SECOND_MATE_ID" ]; then
    echo "ready, waiting: authoritative checkout $PROJ is dirty; commit $READY_COMMIT remains ready in secondmate $SECOND_MATE_ID task $ID" >&2
  else
    echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  fi
  exit 1
fi

if [ -n "$SECOND_MATE_ID" ]; then
  git -C "$PROJ" fetch --quiet --no-tags "$SOURCE_PROJ" "refs/heads/$BRANCH" || {
    echo "error: cannot import ready branch $BRANCH from $SOURCE_PROJ" >&2
    exit 1
  }
  git -C "$PROJ" rev-parse --verify --quiet "$READY_COMMIT^{commit}" >/dev/null || {
    echo "error: imported branch did not provide ready commit $READY_COMMIT" >&2
    exit 1
  }
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
MERGE_TARGET=${READY_COMMIT:-$BRANCH}
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$MERGE_TARGET"; then
  echo "REFUSED: $BRANCH at $MERGE_TARGET is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the worker rebase $BRANCH onto $DEFAULT, record the new exact ready commit, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$MERGE_TARGET" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
if [ -n "$SECOND_MATE_ID" ]; then
  echo "merged exact ready commit $READY_COMMIT from secondmate $SECOND_MATE_ID task $ID into local $DEFAULT ($before -> $after) in $PROJ"
else
  echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
fi
