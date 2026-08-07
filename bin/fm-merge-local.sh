#!/usr/bin/env bash
# Bind and perform the approved local merge for a local-only ship task.
#
# `--prepare` is the review-ready operation. It records ready_head= as the exact
# immutable tip of fm/<id> only while the task worktree is clean and checked out
# at that tip. Run it again after every rebase or fix, then obtain approval for
# the new revision. The merge form never refreshes that binding: it verifies the
# branch and worktree still match and fast-forwards the local default branch to
# the bound commit object itself, not to a movable branch name.
#
# This is firstmate's local merge action and keeps the existing captain/yolo
# authority boundary. It refuses non-local tasks, dirty copies, moved revisions,
# and non-fast-forwards. It never decides approval.
# Usage: fm-merge-local.sh <task-id> [--prepare]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-task-custody-lib.sh
. "$SCRIPT_DIR/fm-task-custody-lib.sh"

"$FM_ROOT/bin/fm-guard.sh" || true
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "usage: fm-merge-local.sh <task-id> [--prepare]" >&2; exit 2; }
ID=$1
ACTION=${2:-merge}
[ "$ACTION" = merge ] || [ "$ACTION" = --prepare ] || { echo "usage: fm-merge-local.sh <task-id> [--prepare]" >&2; exit 2; }
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: no regular metadata for task $ID at $META" >&2
  exit 1
fi

meta_exact() {  # <key>
  local key=$1 count value
  count=$(grep -c "^${key}=" "$META" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^${key}=" "$META" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

PROJ=$(meta_exact project) || { echo "error: task $ID has an absent or ambiguous project identity" >&2; exit 1; }
WT=$(meta_exact worktree) || { echo "error: task $ID has an absent or ambiguous worktree identity" >&2; exit 1; }
MODE=$(meta_exact mode) || MODE=
[ "$MODE" = local-only ] || {
  echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh after approval" >&2
  exit 1
}
[ -d "$PROJ" ] && [ -d "$WT" ] || { echo "error: task $ID project or isolated copy is unavailable" >&2; exit 1; }
fm_task_custody_validate "$STATE" "$ID" "$WT" || exit 1
WT=$FM_TASK_CUSTODY_WORKTREE

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" >/dev/null || {
  echo "error: branch $BRANCH does not exist in $PROJ" >&2
  exit 1
}
BRANCH_HEAD=$(git -C "$PROJ" rev-parse "refs/heads/$BRANCH^{commit}") || exit 1
WT_HEAD=$(git -C "$WT" rev-parse "HEAD^{commit}" 2>/dev/null) || {
  echo "error: isolated copy for task $ID has no readable Git HEAD" >&2
  exit 1
}
WT_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$WT_BRANCH" = "$BRANCH" ] && [ "$WT_HEAD" = "$BRANCH_HEAD" ] || {
  echo "REFUSED: task $ID isolated copy is not checked out at the exact tip of $BRANCH." >&2
  exit 1
}
if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "REFUSED: task $ID isolated copy is dirty; uncommitted work cannot be approved or merged." >&2
  exit 1
fi

if [ "$ACTION" = --prepare ]; then
  STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
  META_DEVICE=$(fm_pr_file_device "$META") || exit 1
  [ "$STATE_DEVICE" = "$META_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
  TMP=$(mktemp "$STATE/.fm-local-ready.XXXXXX") || exit 1
  trap 'rm -f -- "$TMP"' EXIT
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ready_head=*|pr=*|pr_head=*) ;;
      *) printf '%s\n' "$line" >> "$TMP" || exit 1 ;;
    esac
  done < "$META"
  printf 'ready_head=%s\n' "$BRANCH_HEAD" >> "$TMP" || exit 1
  chmod 0600 "$TMP" || exit 1
  fm_pr_private_file_valid "$TMP" 600 "$STATE_DEVICE" || exit 1
  fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
  mv -f -- "$TMP" "$META" || exit 1
  TMP=
  trap - EXIT
  printf 'prepared task %s for review at %s\n' "$ID" "$BRANCH_HEAD"
  exit 0
fi

READY_COUNT=$(grep -c '^ready_head=' "$META" 2>/dev/null || true)
[ "$READY_COUNT" -eq 1 ] || {
  echo "REFUSED: task $ID has no exact local readiness binding; run bin/fm-merge-local.sh $ID --prepare, review that revision, and obtain approval." >&2
  exit 1
}
READY_HEAD=$(grep '^ready_head=' "$META" | cut -d= -f2-)
fm_pr_head_valid "$READY_HEAD" || {
  echo "REFUSED: task $ID has a malformed local readiness revision; prepare it again." >&2
  exit 1
}
[ "$BRANCH_HEAD" = "$READY_HEAD" ] && [ "$WT_HEAD" = "$READY_HEAD" ] || {
  echo "REFUSED: $BRANCH moved after review from $READY_HEAD to $BRANCH_HEAD." >&2
  echo "Run bin/fm-merge-local.sh $ID --prepare, review the new revision, and obtain fresh merge approval." >&2
  exit 1
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
CUR=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || true)
[ "$CUR" = "$DEFAULT" ] || { echo "error: $PROJ is on '$CUR', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$READY_HEAD"; then
  echo "REFUSED: approved revision $READY_HEAD is not a fast-forward of $DEFAULT." >&2
  echo "Have the worker rebase $BRANCH onto $DEFAULT, prepare the new revision, and obtain fresh approval." >&2
  exit 1
fi

BEFORE=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$READY_HEAD" >/dev/null
AFTER=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged approved revision $READY_HEAD from $BRANCH into local $DEFAULT ($BEFORE -> $AFTER) in $PROJ"
