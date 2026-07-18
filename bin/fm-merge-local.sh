#!/usr/bin/env bash
# Perform the approved local landing for a local-only ship task by fast-forwarding
# a clean, checked-out local target branch to the task's fm/<id> branch.
#
# This is firstmate's sanctioned local merge action after captain approval or
# routine yolo authority. Without --target, the target is the project's default
# branch, preserving the original behavior. An explicit --target must name an
# existing local branch and the project's main local copy must already be clean
# and checked out on it. This command never changes branches or contacts a remote.
# It only runs for mode=local-only tasks and only performs a clean
# `git merge --ff-only` after all guards pass. See AGENTS.md prime directives,
# project management, and task lifecycle.
# After a successful fast-forward it atomically records one
# `local_merge_target=<branch>` in the task metadata for teardown verification.
#
# Usage: fm-merge-local.sh <task-id> [--target <local-branch>]
set -eu

usage() {
  cat <<'EOF'
Usage: fm-merge-local.sh <task-id> [--target <local-branch>]

Fast-forward a clean, checked-out local branch to fm/<task-id> for an approved
local-only task. Without --target, the project's default branch is the target.
--target never checks out or creates the requested local branch.
Successful landing records local_merge_target in the task metadata.
EOF
}

fail_usage() {
  echo "error: $1" >&2
  usage >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    fail_usage "missing task id"
    ;;
  -*)
    fail_usage "unknown option '$1'"
    ;;
esac

ID=$1
fm_task_id_path_safe "$ID" || fail_usage "invalid task id"
shift
REQUESTED_TARGET=
if [ "$#" -gt 0 ]; then
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || fail_usage "--target requires a local branch name"
      [ "$#" -eq 2 ] || fail_usage "unexpected extra argument '${3:-}'"
      [ -n "$2" ] || fail_usage "--target requires a non-empty local branch name"
      REQUESTED_TARGET=$2
      ;;
    --*)
      fail_usage "unknown option '$1'"
      ;;
    *)
      fail_usage "unexpected positional argument '$1'"
      ;;
  esac
fi

if [ -n "$REQUESTED_TARGET" ]; then
  case "$REQUESTED_TARGET" in
    -*|*[[:space:]]*)
      fail_usage "unsafe or option-like target branch '$REQUESTED_TARGET'"
      ;;
  esac
  single_quote=$(printf '\047')
  backslash=$(printf '\134')
  for unsafe_char in '$' '`' ';' '|' '&' '<' '>' "$backslash" "$single_quote" '"' '(' ')' '{' '}'; do
    case "$REQUESTED_TARGET" in
      *"$unsafe_char"*)
        fail_usage "unsafe or option-like target branch '$REQUESTED_TARGET'"
        ;;
    esac
  done
  git check-ref-format --branch "$REQUESTED_TARGET" >/dev/null 2>&1 \
    || fail_usage "invalid target branch '$REQUESTED_TARGET'"
fi

META="$STATE/$ID.meta"
STATE_DEVICE=$(fm_pr_file_device "$STATE") \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
if ! fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || [ ! -f "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
META_MODE=$(fm_pr_file_mode "$META") || exit 1
META_IDENTITY=$(fm_pr_file_identity "$META") || exit 1

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

if [ -n "$REQUESTED_TARGET" ]; then
  TARGET=$REQUESTED_TARGET
else
  TARGET=$(default_branch) || { echo "error: cannot determine target default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
fi

BRANCH="fm/$ID"
TARGET_REF="refs/heads/$TARGET"
BRANCH_REF="refs/heads/$BRANCH"

[ "$TARGET" != "$BRANCH" ] || { echo "error: target branch '$TARGET' is the task branch; refusing to merge a branch into itself" >&2; exit 1; }
git -C "$PROJ" show-ref --verify --quiet "$TARGET_REF" || { echo "error: target branch '$TARGET' does not exist locally in $PROJ" >&2; exit 1; }
git -C "$PROJ" show-ref --verify --quiet "$BRANCH_REF" || { echo "error: task branch '$BRANCH' does not exist in $PROJ; target '$TARGET' was not changed" >&2; exit 1; }

# The project's main local copy must already be on the target and clean, so the
# fast-forward lands predictably without checkout, stash, reset, or force.
cur=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$TARGET" ] || { echo "error: $PROJ is on '$cur', expected target branch '$TARGET'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into target '$TARGET'" >&2
  exit 1
fi

# Clean fast-forward only: the fully qualified target must be an ancestor of the
# fully qualified task branch.
if ! git -C "$PROJ" merge-base --is-ancestor "$TARGET_REF" "$BRANCH_REF"; then
  echo "REFUSED: task branch '$BRANCH' is not a fast-forward of target '$TARGET' (it has diverged)." >&2
  echo "Have the worker rebase '$BRANCH' onto '$TARGET', then retry." >&2
  exit 1
fi

META_TMP=
merge_local_cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap merge_local_cleanup EXIT
trap 'exit 1' HUP INT TERM
META_TMP=$(mktemp "$STATE/.fm-merge-local-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    local_merge_target=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'local_merge_target=%s\n' "$TARGET" >> "$META_TMP" || exit 1
chmod "$META_MODE" "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" "$META_MODE" "$STATE_DEVICE" || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" \
  || { echo "error: task metadata changed during local merge preparation" >&2; exit 1; }
[ "$(fm_pr_file_identity "$META")" = "$META_IDENTITY" ] \
  || { echo "error: task metadata changed during local merge preparation" >&2; exit 1; }

before=$(git -C "$PROJ" rev-parse --short "$TARGET_REF")
git -C "$PROJ" merge --ff-only "$BRANCH_REF" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$TARGET_REF")
fm_pr_regular_destination_on_device_or_absent "$META" "$META_DEVICE" \
  || { echo "error: task metadata changed during local merge" >&2; exit 1; }
[ "$(fm_pr_file_identity "$META")" = "$META_IDENTITY" ] \
  || { echo "error: task metadata changed during local merge" >&2; exit 1; }
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" "$META_MODE" "$STATE_DEVICE" || exit 1
echo "merged $BRANCH into local target $TARGET ($before -> $after) in $PROJ"
