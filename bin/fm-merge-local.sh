#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's checked-out clean target branch to the crewmate's fm/<id> branch.
# The target defaults to the project's resolved default branch exactly as before.
# An exact Captain-approved landing may instead name an existing local integration branch
# with --target-branch; the helper never switches branches and records the chosen
# branch as pending before the ref update and completed afterward.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh [--target-branch <branch>] <task-id>
set -eu

usage() {
  cat <<'EOF'
Usage: fm-merge-local.sh [--target-branch <branch>] <task-id>

Fast-forward the project's currently checked-out clean target branch from the
local-only task branch fm/<task-id>. Without --target-branch, the target remains
the project's resolved default branch: origin/HEAD, then local main or master.
The explicit target must be an existing local branch and must already be checked
out; this command never switches it.
EOF
}

usage_error() {
  echo "error: $1" >&2
  usage >&2
  exit 2
}

TARGET=
TARGET_SET=0
ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --target-branch)
      [ "$TARGET_SET" -eq 0 ] || usage_error "--target-branch may be specified only once"
      [ "$#" -ge 2 ] || usage_error "--target-branch requires a branch name"
      case "$2" in
        --*) usage_error "--target-branch requires a branch name" ;;
      esac
      TARGET=$2
      TARGET_SET=1
      shift 2
      ;;
    --target-branch=*)
      usage_error "use --target-branch <branch>"
      ;;
    --*)
      usage_error "unknown option: $1"
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      [ -z "$ID" ] || usage_error "unexpected argument: $1"
      ID=$1
      shift
      ;;
  esac
done
[ -n "$ID" ] || usage_error "task id is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
META_LOCK=$(fm_meta_lock_path "$META") || { echo "error: invalid task metadata path: $META" >&2; exit 1; }
META_LOCK_HELD=0
META_TMP=
merge_local_cleanup() {
  local status=$?
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  return "$status"
}
trap merge_local_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
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
TASK_REF="refs/heads/$BRANCH"
git -C "$PROJ" rev-parse --verify --quiet "$TASK_REF" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

if [ "$TARGET_SET" -eq 1 ]; then
  git -C "$PROJ" check-ref-format --branch "$TARGET" >/dev/null 2>&1 \
    || { echo "error: invalid target branch name '$TARGET'" >&2; exit 1; }
  git -C "$PROJ" show-ref --verify --quiet "refs/heads/$TARGET" \
    || { echo "error: target branch '$TARGET' does not exist in $PROJ" >&2; exit 1; }
else
  TARGET=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
fi

[ "$TARGET" != "$BRANCH" ] || { echo "error: target branch '$TARGET' is the task branch; refusing to merge a branch into itself" >&2; exit 1; }
TARGET_REF="refs/heads/$TARGET"

# The project's main checkout must already be on the exact target branch and
# clean, so the fast-forward lands predictably (firstmate never writes here
# otherwise). The default-target refusal retains its established wording.
cur_ref=$(git -C "$PROJ" symbolic-ref --quiet HEAD 2>/dev/null || echo "")
cur=${cur_ref#refs/heads/}
if [ "$TARGET_SET" -eq 1 ]; then
  [ "$cur_ref" = "$TARGET_REF" ] || { echo "error: $PROJ is on '$cur', expected target branch '$TARGET'; cannot merge safely" >&2; exit 1; }
else
  [ "$cur_ref" = "$TARGET_REF" ] || { echo "error: $PROJ is on '$cur', expected default branch '$TARGET'; cannot merge safely" >&2; exit 1; }
fi
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: TARGET must be an ancestor of BRANCH. Fully qualified
# local refs prevent a same-named tag or remote ref from making either side
# ambiguous.
if ! git -C "$PROJ" merge-base --is-ancestor "$TARGET_REF" "$TASK_REF"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $TARGET (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $TARGET, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$TARGET_REF")
publish_merge_target() {
  local phase=$1 line key=local_merge_target
  [ "$phase" != pending ] || key=local_merge_target_pending
  META_TMP=$(mktemp "$STATE/.fm-merge-local-meta.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      local_merge_target_pending=*) ;;
      local_merge_target=*)
        if [ "$phase" = pending ]; then
          printf '%s\n' "$line" >> "$META_TMP" || return 1
        fi
        ;;
      *) printf '%s\n' "$line" >> "$META_TMP" || return 1 ;;
    esac
  done < "$META"
  printf '%s=%s\n' "$key" "$TARGET" >> "$META_TMP" || return 1
  chmod 0600 "$META_TMP" || return 1
  mv -f -- "$META_TMP" "$META" || return 1
  META_TMP=
}
publish_merge_target pending || exit 1
git -C "$PROJ" merge --ff-only "$TASK_REF" >/dev/null || exit 1
publish_merge_target completed || exit 1
after=$(git -C "$PROJ" rev-parse --short "$TARGET_REF")
echo "merged $BRANCH into local $TARGET ($before -> $after) in $PROJ"
