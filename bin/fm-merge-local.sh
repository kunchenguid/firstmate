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
# exact fast-forward. Untracked files, ignored files, and changes at paths the
# fast-forward never touches cannot be clobbered by it, so they do not block it,
# and a refusal names every colliding path and what the incoming commits do to
# it. A state this guard cannot classify confidently - an unresolved conflict, an
# unrecognized status code, a git command that fails - refuses instead of
# proceeding.
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

# The project's main checkout must be on its default branch, so the fast-forward
# lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
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

# An unclassifiable state is not a safe state, so every parse or command failure
# lands here rather than degrading into an empty - and therefore silent - change set.
refuse_unreadable() {  # <detail>
  echo "REFUSED: cannot classify the state of $PROJ, so refusing to merge into it." >&2
  echo "  $1" >&2
  echo "Resolve that state in $PROJ (finish or abort an unresolved merge, or report an unexpected git status), then retry." >&2
  exit 1
}

DIRTY_PATHS=()      # tracked paths carrying staged or unstaged changes
UNTRACKED_PATHS=()  # untracked, non-ignored files
INC_PATHS=()        # paths the fast-forward rewrites
INC_ACTIONS=()      # what it does to INC_PATHS[i]: changes, removes, or adds
INC_ADDS=()         # paths the fast-forward creates

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
  case "${code:1:1}" in
    ' '|M|T|D|R|C) : ;;
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

git -C "$PROJ" diff -z --name-status "$DEFAULT" "$BRANCH" > "$GUARD_TMP/incoming" \
  || refuse_unreadable "git diff failed between $DEFAULT and $BRANCH in $PROJ"

# Records are "<status>\0<path>\0", and for rename/copy "<status>\0<old>\0<new>\0"
# (source first, the reverse of the status field order above).
while IFS= read -r -d '' change; do
  IFS= read -r -d '' path || refuse_unreadable "truncated '$change' entry in the incoming diff"
  case "$change" in
    A)
      INC_PATHS+=("$path"); INC_ACTIONS+=(adds); INC_ADDS+=("$path")
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
      INC_PATHS+=("$other"); INC_ACTIONS+=(adds); INC_ADDS+=("$other")
      ;;
    C|C[0-9]*)
      IFS= read -r -d '' other || refuse_unreadable "truncated '$change' entry at '$path' in the incoming diff"
      INC_PATHS+=("$other"); INC_ACTIONS+=(adds); INC_ADDS+=("$other")
      ;;
    *)
      refuse_unreadable "unrecognized git diff status '$change' at '$path'"
      ;;
  esac
done < "$GUARD_TMP/incoming"

# Echo what the fast-forward does to <path>, or fail when it leaves it alone.
incoming_action() {  # <path>
  local want=$1 i=0
  while [ "$i" -lt "${#INC_PATHS[@]}" ]; do
    if [ "${INC_PATHS[$i]}" = "$want" ]; then
      printf '%s\n' "${INC_ACTIONS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# True when the fast-forward creates a file at <path>, where an untracked file of
# the operator's own would be in the way.
incoming_creates() {  # <path> <created-path>...
  local want=$1 candidate
  shift
  for candidate in "$@"; do
    [ "$candidate" = "$want" ] && return 0
  done
  return 1
}

COLLISIONS=()
if [ "${#DIRTY_PATHS[@]}" -gt 0 ]; then
  for path in "${DIRTY_PATHS[@]}"; do
    if action=$(incoming_action "$path"); then
      COLLISIONS+=("$path - uncommitted changes here, and this merge $action it")
    fi
  done
fi
if [ "${#UNTRACKED_PATHS[@]}" -gt 0 ] && [ "${#INC_ADDS[@]}" -gt 0 ]; then
  for path in "${UNTRACKED_PATHS[@]}"; do
    if incoming_creates "$path" "${INC_ADDS[@]}"; then
      COLLISIONS+=("$path - untracked file here, and this merge creates a file at that path")
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
