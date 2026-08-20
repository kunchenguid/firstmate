#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. Its only dirty-tree recognition is
# for unstaged ordinary tracked-file modifications whose blobs already equal the
# target branch: it makes no project mutation, because the files are already
# correct, and instead prints a safe manual landing command. See AGENTS.md prime
# directives, project management, and task lifecycle.
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

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }

DIRTY_PATHS=()
TARGET=

target_entry() {
  local path=$1 entry mode type hash extra
  entry=$(GIT_LITERAL_PATHSPECS=1 git -C "$PROJ" ls-tree \
    --format='%(objectmode) %(objecttype) %(objectname)' "$TARGET" -- "$path") || return 1
  [ -n "$entry" ] || return 1
  case "$entry" in
    *$'\n'*) return 1 ;;
  esac
  IFS=' ' read -r mode type hash extra <<< "$entry"
  [ -n "$mode" ] && [ "$type" = blob ] && [ -n "$hash" ] && [ -z "$extra" ] || return 1
  [ "$mode" != 160000 ] || return 1
  printf '%s\n' "$hash"
}

detect_identical_dirty_tree() {
  local record index_status worktree_status path target_hash working status_complete='' dirty_seen=0
  DIRTY_PATHS=()
  while IFS= read -r -d '' record; do
    case "$record" in
      __FM_MERGE_LOCAL_STATUS__0)
        status_complete=0
        continue
        ;;
      __FM_MERGE_LOCAL_STATUS__*)
        return 2
        ;;
    esac
    [ -z "$status_complete" ] || return 2
    dirty_seen=1
    [ "${#record}" -ge 4 ] || return 1
    index_status=${record:0:1}
    worktree_status=${record:1:1}
    [ "${record:2:1}" = ' ' ] || return 1
    case "$index_status" in
      ' ') ;;
      *) return 1 ;;
    esac
    case "$worktree_status" in
      M) ;;
      *) return 1 ;;
    esac
    path=${record:3}
    [ -n "$path" ] || return 1
    GIT_LITERAL_PATHSPECS=1 git -C "$PROJ" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || return 1
    target_hash=$(target_entry "$path") || return 1
    working=$(git -C "$PROJ" hash-object --no-filters -- "$path") || return 1
    [ "$working" = "$target_hash" ] || return 1
    DIRTY_PATHS+=("$path")
  done < <(
    if git -C "$PROJ" status --porcelain=v1 -z --untracked-files=all; then
      printf '__FM_MERGE_LOCAL_STATUS__0\0'
    else
      printf '__FM_MERGE_LOCAL_STATUS__1\0'
    fi
  )
  [ "$status_complete" = 0 ] || return 2
  [ "$dirty_seen" -gt 0 ] || return 3
  [ "${#DIRTY_PATHS[@]}" -gt 0 ]
}

shell_quote() {
  local value=$1
  printf '%q' "$value"
}

accepted_paths_message() {
  local path rendered message=
  for path in "${DIRTY_PATHS[@]}"; do
    rendered=$(shell_quote "$path")
    if [ -n "$message" ]; then
      message+=", "
    fi
    message+=$rendered
  done
  printf '%s\n' "$message"
}

accepted_paths_shell_words() {
  local path rendered words=
  for path in "${DIRTY_PATHS[@]}"; do
    rendered=$(shell_quote "$path")
    if [ -n "$words" ]; then
      words+=' '
    fi
    words+=$rendered
  done
  printf '%s\n' "$words"
}

report_identical_dirty_tree() {
  local paths path_args project branch
  paths=$(accepted_paths_message)
  path_args=$(accepted_paths_shell_words)
  project=$(shell_quote "$PROJ")
  branch=$(shell_quote "$BRANCH")
  echo "detected identical dirty paths: $paths (each already contains exactly the content $BRANCH will land); no project changes were made" >&2
  echo "The listed paths already contain exactly the content $BRANCH will land, so staging them discards nothing." >&2
  echo "To land by hand: git -C $project add -- $path_args && git -C $project merge --ff-only $branch" >&2
}

TARGET=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH") || {
  echo "error: $PROJ working tree could not be inspected safely; refusing to merge into it" >&2
  exit 1
}
if detect_identical_dirty_tree; then
  if git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$TARGET"; then
    report_identical_dirty_tree
    exit 2
  fi
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
else
  scan_result=$?
fi
case "$scan_result" in
  1)
    echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
    exit 1
    ;;
  2)
    echo "error: $PROJ working tree could not be inspected safely; refusing to merge into it" >&2
    exit 1
    ;;
  3)
    ;;
  *)
    echo "error: $PROJ working tree could not be inspected safely; refusing to merge into it" >&2
    exit 1
    ;;
esac

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
