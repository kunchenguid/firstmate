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
#
# Uncommitted work in the project blocks the merge only on a GENUINE COLLISION:
# a path that is both uncommitted in the project checkout and rewritten by this
# exact fast-forward, including an untracked entry and an incoming path that
# cannot both exist because one is a directory where the other is a file. Ignored
# files, and untracked or modified paths the fast-forward never touches, cannot
# be clobbered by it, so they do not block it, and a refusal names every
# colliding path and what the incoming commits do to it. A state this guard
# cannot classify confidently - an unresolved conflict, a merge, cherry-pick,
# revert, rebase, bisect, or patch application left in progress, an unrecognized
# status code, a git command that fails - refuses instead of proceeding, naming
# the operation it found and how to conclude or abandon it.
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

# --- unclassifiable-state refusals -------------------------------------------
#
# An unclassifiable state is not a safe state, so every parse or command failure
# lands here rather than degrading into an empty - and therefore silent - change set.
refuse_unreadable() {  # <detail>
  echo "REFUSED: cannot classify the state of $PROJ, so refusing to merge into it." >&2
  echo "  $1" >&2
  echo "Resolve that state in $PROJ (finish or abort the operation in progress, or report an unexpected git status), then retry." >&2
  exit 1
}

# A merge, cherry-pick, revert, rebase, bisect, or patch application left
# half-finished is such a state, and one no other check can see on its own: once
# its conflicts are staged, git status reports plain modifications
# indistinguishable from ordinary dirt. Resolve each sentinel through
# rev-parse --git-path rather than assuming "$PROJ/.git": in a linked worktree
# the git dir is elsewhere, and a hardcoded path would silently never fire.
IN_PROGRESS_PATH=
in_progress_path() {  # <git-dir-entry>
  local rel
  rel=$(git -C "$PROJ" rev-parse --git-path "$1") \
    || refuse_unreadable "git rev-parse --git-path $1 failed in $PROJ"
  case "$rel" in
    /*) IN_PROGRESS_PATH=$rel ;;
    *) IN_PROGRESS_PATH="$PROJ/$rel" ;;
  esac
}

refuse_if_in_progress() {  # <git-dir-entry> <detail>
  in_progress_path "$1"
  [ -e "$IN_PROGRESS_PATH" ] || return 0
  refuse_unreadable "$2"
}

# `git am` and the apply-backend rebase share the rebase-apply directory but need
# different advice - `git rebase --abort` refuses outright while an am is open.
# git's own status tells them apart by the `applying` marker inside it, so this
# does too, and checks that marker before the directory it lives in.
refuse_if_operation_in_progress() {
  refuse_if_in_progress MERGE_HEAD \
    "a merge is in progress here; conclude it with 'git commit' or abandon it with 'git merge --abort'"
  refuse_if_in_progress CHERRY_PICK_HEAD \
    "a cherry-pick is in progress here; conclude it with 'git cherry-pick --continue' or abandon it with 'git cherry-pick --abort'"
  refuse_if_in_progress REVERT_HEAD \
    "a revert is in progress here; conclude it with 'git revert --continue' or abandon it with 'git revert --abort'"
  # A multi-commit cherry-pick or revert keeps its remaining picks in the
  # sequencer after the conflicted one is resolved and committed, which drops
  # CHERRY_PICK_HEAD while the sequence is still open. That marker is checked
  # last of the three so a sequence still carrying its live conflict keeps the
  # more specific message above. The interactive rebase does not appear here: it
  # keeps its todo list in rebase-merge, which the next sentinel covers.
  refuse_if_in_progress sequencer/todo \
    "a cherry-pick or revert sequence is in progress here; conclude it with 'git cherry-pick --continue' or 'git revert --continue', or abandon it with 'git cherry-pick --abort' or 'git revert --abort'"
  refuse_if_in_progress rebase-merge \
    "a rebase is in progress here; conclude it with 'git rebase --continue' or abandon it with 'git rebase --abort'"
  refuse_if_in_progress rebase-apply/applying \
    "a patch application is in progress here; conclude it with 'git am --continue' or abandon it with 'git am --abort'"
  refuse_if_in_progress rebase-apply \
    "a rebase is in progress here; conclude it with 'git rebase --continue' or abandon it with 'git rebase --abort'"
  refuse_if_in_progress BISECT_LOG \
    "a bisect is in progress here; end it with 'git bisect reset'"
}

# The project's main checkout must be on its default branch, so the fast-forward
# lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -z "$cur" ]; then
  # A rebase and a bisect both park the checkout on a detached HEAD, so the
  # sentinels have to answer here or they never run at all: the generic refusal
  # below reports an empty branch name and says nothing about the operation that
  # caused it.
  refuse_if_operation_in_progress
fi
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH. Settled before
# the collision guard below, so that guard's incoming change set is exactly the
# set of paths this fast-forward rewrites rather than a diverged two-way diff.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# --- working-tree collision guard -------------------------------------------
#
# A blanket "any uncommitted change refuses" check is stricter than git itself
# and self-deadlocking: it blocks the very commit that would settle the
# uncommitted entries (adding ignore rules, dropping a machine-local pointer from
# the index), because the cure sits behind the symptom. So refuse only where the
# fast-forward could actually destroy local work.
#
# Both sides are read NUL-delimited. -z is not an optimization here: it is the
# only status and diff format that emits paths verbatim instead of quoting names
# with spaces or non-ASCII bytes. --untracked-files=all is required so untracked
# entries are individual files rather than a collapsed parent directory, which
# would hide a collision at a nested path. Ignored files are absent from this
# listing (no --ignored), which is why they never collide.

GUARD_TMP=
guard_tmp_cleanup() {
  [ -n "$GUARD_TMP" ] || return 0
  rm -rf "$GUARD_TMP"
  GUARD_TMP=
}
trap guard_tmp_cleanup EXIT
GUARD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-local.XXXXXX") || {
  echo "error: cannot create a temporary directory to inspect $PROJ" >&2
  exit 1
}

DIRTY_PATHS=()      # tracked paths carrying staged or unstaged changes
UNTRACKED_PATHS=()  # untracked, non-ignored files
INC_PATHS=()        # paths the fast-forward rewrites
INC_ACTIONS=()      # what it does to INC_PATHS[i]: changes, removes, or adds

git -C "$PROJ" status --porcelain=v1 -z --untracked-files=all > "$GUARD_TMP/status" \
  || refuse_unreadable "git status failed in $PROJ"

# Records are "XY <path>\0". Rename and copy entries carry a second NUL field
# holding the other endpoint, which must be consumed from the same stream or
# every later record is misread as a status code.
while IFS= read -r -d '' entry; do
  code=${entry:0:2}
  path=${entry:3}
  case "$code" in
    '??')
      UNTRACKED_PATHS+=("$path")
      continue
      ;;
    'DD'|'AA'|U?|?U)
      refuse_unreadable "unresolved merge conflict at '$path'"
      ;;
  esac
  case "${code:0:1}" in
    ' '|M|T|A|D|R|C) : ;;
    *) refuse_unreadable "unrecognized git status code '$code' at '$path'" ;;
  esac
  # 'A' on the worktree side is an intent-to-add entry (`git add -N`), which is an
  # ordinary dirty tracked path; the collision intersection below decides it, the
  # same as a modification. Every code outside these two sets still refuses,
  # because a state this cannot classify is not a safe state.
  case "${code:1:1}" in
    ' '|M|T|A|D|R|C) : ;;
    *) refuse_unreadable "unrecognized git status code '$code' at '$path'" ;;
  esac
  DIRTY_PATHS+=("$path")
  case "$code" in
    *R*|*C*)
      IFS= read -r -d '' other || refuse_unreadable "truncated '$code' rename entry at '$path'"
      DIRTY_PATHS+=("$other")
      ;;
  esac
done < "$GUARD_TMP/status"

# An operation that kept HEAD attached reaches the sentinels here rather than at
# the detached-HEAD check above, deliberately after the listing: one still
# carrying live conflicts is named by the conflicted path it left behind, and
# these catch it once its resolutions are staged and it has nothing left to show.
refuse_if_operation_in_progress

# The trailing `--` is load-bearing: without it git applies its revision/filename
# ambiguity check to both arguments and dies outright in any project holding a
# root entry named like its default branch, which would refuse a landing the
# operator cannot settle. No other git call here takes a pathspec, so none of the
# others can read a revision as a filename.
git -C "$PROJ" diff -z --name-status "$DEFAULT" "$BRANCH" -- > "$GUARD_TMP/incoming" \
  || refuse_unreadable "git diff failed between $DEFAULT and $BRANCH in $PROJ"

# Records are "<status>\0<path>\0", and for rename/copy "<status>\0<old>\0<new>\0"
# (source first, the reverse of the status field order above).
while IFS= read -r -d '' change; do
  IFS= read -r -d '' path || refuse_unreadable "truncated '$change' entry in the incoming diff"
  case "$change" in
    A)
      INC_PATHS+=("$path"); INC_ACTIONS+=(adds)
      ;;
    M|M[0-9]*|T|T[0-9]*)
      INC_PATHS+=("$path"); INC_ACTIONS+=(changes)
      ;;
    D)
      INC_PATHS+=("$path"); INC_ACTIONS+=(removes)
      ;;
    R|R[0-9]*)
      IFS= read -r -d '' other || refuse_unreadable "truncated '$change' entry at '$path' in the incoming diff"
      INC_PATHS+=("$path"); INC_ACTIONS+=(removes)
      INC_PATHS+=("$other"); INC_ACTIONS+=(adds)
      ;;
    C|C[0-9]*)
      IFS= read -r -d '' other || refuse_unreadable "truncated '$change' entry at '$path' in the incoming diff"
      INC_PATHS+=("$other"); INC_ACTIONS+=(adds)
      ;;
    *)
      refuse_unreadable "unrecognized git diff status '$change' at '$path'"
      ;;
  esac
done < "$GUARD_TMP/incoming"

# Set INC_ACTION to what the fast-forward does to <path>, or fail when it leaves
# it alone. Both lookups below assign a global rather than echoing: a command
# substitution would fork a subshell per dirty path in a large checkout, and
# would also swallow the `exit` a refusal depends on.
INC_ACTION=
incoming_action() {  # <path>
  local want=$1 i=0
  while [ "$i" -lt "${#INC_PATHS[@]}" ]; do
    if [ "${INC_PATHS[$i]}" = "$want" ]; then
      INC_ACTION=${INC_ACTIONS[$i]}
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Set UNTRACKED_COLLISION to how the fast-forward would have to disturb the
# untracked entry at <path> to land, or fail when it can leave that entry alone.
# git refuses all three shapes, so name them here rather than letting git emit
# its own abort: the merge's file at that exact path, a file where the merge
# needs a directory, and a directory where the merge needs a file.
UNTRACKED_COLLISION=
untracked_collision() {  # <path>
  local want=$1 i=0 add
  while [ "$i" -lt "${#INC_PATHS[@]}" ]; do
    if [ "${INC_ACTIONS[$i]}" = adds ]; then
      add=${INC_PATHS[$i]}
      if [ "$add" = "$want" ]; then
        UNTRACKED_COLLISION="untracked file here, and this merge creates a file at that path"
        return 0
      fi
      case "$add" in
        "$want"/*)
          UNTRACKED_COLLISION="untracked file here, and this merge needs that path to be a directory to create '$add'"
          return 0
          ;;
      esac
      case "$want" in
        "$add"/*)
          UNTRACKED_COLLISION="untracked file here, and this merge creates a file at '$add', replacing the directory holding it"
          return 0
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 1
}

COLLISIONS=()
if [ "${#DIRTY_PATHS[@]}" -gt 0 ]; then
  for path in "${DIRTY_PATHS[@]}"; do
    if incoming_action "$path"; then
      COLLISIONS+=("$path - uncommitted changes here, and this merge $INC_ACTION it")
    fi
  done
fi
if [ "${#UNTRACKED_PATHS[@]}" -gt 0 ]; then
  for path in "${UNTRACKED_PATHS[@]}"; do
    if untracked_collision "$path"; then
      COLLISIONS+=("$path - $UNTRACKED_COLLISION")
    fi
  done
fi

if [ "${#COLLISIONS[@]}" -gt 0 ]; then
  echo "REFUSED: uncommitted work in $PROJ collides with the $BRANCH fast-forward:" >&2
  for collision in "${COLLISIONS[@]}"; do
    echo "  $collision" >&2
  done
  echo "Commit, stash, or remove exactly those paths, then retry; other uncommitted files do not block this merge." >&2
  exit 1
fi
guard_tmp_cleanup

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
