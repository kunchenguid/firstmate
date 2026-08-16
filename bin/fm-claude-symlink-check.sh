#!/usr/bin/env bash
# Guard against a CLAUDE.md -> AGENTS.md symlink silently turning into (or being
# replaced by) a regular file or a dangling gap during a worker's own branch
# work, before that state ever reaches a PR.
#
# Root cause this guards against: when a project adopts "CLAUDE.md is a symlink
# to AGENTS.md" as its one-source-of-truth convention, any branch whose history
# predates that adoption still carries the old regular-file CLAUDE.md blob.
# Syncing or merging such a branch against a base that now has the symlink hits
# an ordinary git "distinct types on each side" conflict on that path, and
# resolving that conflict by hand is error-prone: it is easy to `git rm` or
# otherwise drop the file instead of keeping the symlink side. This is not a
# bug in any one tool; it is a routine hazard of merging stale branches, so the
# only reliable catch is a check that runs late enough to see the real result.
#
# Project-agnostic: skips silently (exit 0) whenever the resolved base does not
# manage CLAUDE.md as a symlink, so it is a no-op everywhere except a project
# that has actually made this choice.
#
# Where the base does manage it, both the working tree and the current branch
# tip must carry the symlink: a PR ships commits, so a restore left uncommitted
# would still hand the conflict to whoever merges the branch.
#
# Usage: fm-claude-symlink-check.sh [dir] [base-ref]
#   dir       repo or worktree to check (default: .)
#   base-ref  git ref to compare CLAUDE.md against (default: auto-detect the
#             remote-tracking default branch, falling back to a local one)
set -eu

usage() {
  echo "usage: fm-claude-symlink-check.sh [dir] [base-ref]" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -le 2 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)

git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: not a git working tree: $DIR" >&2
  exit 1
}

TOPLEVEL=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$TOPLEVEL" ] || {
  echo "error: cannot resolve the repository root of $DIR" >&2
  exit 1
}
DIR=$(cd "$TOPLEVEL" && pwd -P)

EXPLICIT_BASE=${2:-}

resolve_base() {
  local ref name b
  if [ -n "$EXPLICIT_BASE" ]; then
    printf '%s\n' "$EXPLICIT_BASE"
    return 0
  fi
  ref=$(git -C "$DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  case "$ref" in
    origin/*)
      name=${ref#origin/}
      if git -C "$DIR" show-ref --verify --quiet "refs/remotes/origin/$name"; then
        printf 'origin/%s\n' "$name"
        return 0
      fi
      ;;
  esac
  for b in main master; do
    if git -C "$DIR" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf 'origin/%s\n' "$b"
      return 0
    fi
  done
  for b in main master; do
    if git -C "$DIR" show-ref --verify --quiet "refs/heads/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

BASE=$(resolve_base) || {
  exit 0
}

git -C "$DIR" rev-parse --verify --quiet "$BASE^{tree}" >/dev/null || {
  echo "error: base ref '$BASE' does not resolve to a tree in $DIR" >&2
  exit 1
}

# ls-tree output: "<mode> <type> <sha>\t<path>"; empty when the path is absent.
BASE_ENTRY=$(git -C "$DIR" ls-tree --full-tree "$BASE" -- CLAUDE.md) || {
  echo "error: cannot read CLAUDE.md out of '$BASE' in $DIR" >&2
  exit 1
}
if [ -z "$BASE_ENTRY" ]; then
  exit 0
fi
BASE_MODE=$(printf '%s\n' "$BASE_ENTRY" | awk '{print $1}')
BASE_BLOB=$(printf '%s\n' "$BASE_ENTRY" | awk '{print $3}')

if [ "$BASE_MODE" != 120000 ]; then
  exit 0
fi

EXPECTED_TARGET=$(git -C "$DIR" cat-file -p "$BASE_BLOB") || {
  echo "error: cannot read the CLAUDE.md symlink target out of '$BASE' in $DIR" >&2
  exit 1
}

tree_entry_is_regular_file() {
  local entry=$1 mode type
  [ -n "$entry" ] || return 1
  mode=$(printf '%s\n' "$entry" | awk '{print $1}')
  type=$(printf '%s\n' "$entry" | awk '{print $2}')
  [ "$type" = blob ] || return 1
  case "$mode" in
    100*) return 0 ;;
    *) return 1 ;;
  esac
}

BASE_TARGET_ENTRY=$(git -C "$DIR" --literal-pathspecs ls-tree --full-tree "$BASE" -- "$EXPECTED_TARGET") || {
  echo "error: cannot read the expected target '$EXPECTED_TARGET' out of '$BASE' in $DIR" >&2
  exit 1
}
if ! tree_entry_is_regular_file "$BASE_TARGET_ENTRY"; then
  echo "error: the expected target '$EXPECTED_TARGET' is not a regular file in '$BASE' in $DIR" >&2
  exit 1
fi

CLAUDE="$DIR/CLAUDE.md"

shell_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

restore_claude_command() {
  printf 'git -C %s checkout %s -- %s   (or: ln -sfn -- %s %s)' \
    "$(shell_quote "$DIR")" \
    "$(shell_quote "$BASE")" \
    "$(shell_quote CLAUDE.md)" \
    "$(shell_quote "$EXPECTED_TARGET")" \
    "$(shell_quote "$CLAUDE")"
}

restore_target_command() {
  printf 'git -C %s --literal-pathspecs checkout %s -- %s' \
    "$(shell_quote "$DIR")" \
    "$(shell_quote "$BASE")" \
    "$(shell_quote "$EXPECTED_TARGET")"
}

stage_target_command() {
  printf 'git -C %s --literal-pathspecs add -f -- %s' \
    "$(shell_quote "$DIR")" \
    "$(shell_quote "$EXPECTED_TARGET")"
}

commit_branch_tip_command() {
  if [ "$1" = 1 ]; then
    printf 'git -C %s --literal-pathspecs add -f -- %s && git -C %s --literal-pathspecs add -f -- %s && git -C %s --literal-pathspecs commit -m %s -- %s %s' \
      "$(shell_quote "$DIR")" \
      "$(shell_quote CLAUDE.md)" \
      "$(shell_quote "$DIR")" \
      "$(shell_quote "$EXPECTED_TARGET")" \
      "$(shell_quote "$DIR")" \
      "$(shell_quote 'fix: restore the CLAUDE.md symlink')" \
      "$(shell_quote CLAUDE.md)" \
      "$(shell_quote "$EXPECTED_TARGET")"
  else
    printf 'git -C %s --literal-pathspecs add -f -- %s && git -C %s --literal-pathspecs commit -m %s -- %s' \
      "$(shell_quote "$DIR")" \
      "$(shell_quote CLAUDE.md)" \
      "$(shell_quote "$DIR")" \
      "$(shell_quote 'fix: restore the CLAUDE.md symlink')" \
      "$(shell_quote CLAUDE.md)"
  fi
}

if [ ! -e "$CLAUDE" ] && [ ! -L "$CLAUDE" ]; then
  echo "error: CLAUDE.md is missing in $DIR, but $BASE manages it as a symlink -> $EXPECTED_TARGET." >&2
  echo "Restore it: $(restore_claude_command)" >&2
  exit 1
fi
if [ ! -L "$CLAUDE" ]; then
  echo "error: CLAUDE.md in $DIR is a regular file, but $BASE manages it as a symlink -> $EXPECTED_TARGET." >&2
  echo "This is the classic 'distinct types on each side' merge fallout: a pre-conversion branch clobbered the symlink." >&2
  echo "Restore it: $(restore_claude_command)" >&2
  exit 1
fi

ACTUAL_TARGET=$(readlink "$CLAUDE")
if [ "$ACTUAL_TARGET" != "$EXPECTED_TARGET" ]; then
  echo "error: CLAUDE.md in $DIR is a symlink to '$ACTUAL_TARGET', but $BASE expects '$EXPECTED_TARGET'." >&2
  echo "Restore it: $(restore_claude_command)" >&2
  exit 1
fi
if [ ! -e "$CLAUDE" ]; then
  echo "error: CLAUDE.md in $DIR is a dangling symlink: its target '$EXPECTED_TARGET' does not exist." >&2
  echo "Restore the target: $(restore_target_command)" >&2
  exit 1
fi
case "$EXPECTED_TARGET" in
  /*) WORKTREE_TARGET_PATH=$EXPECTED_TARGET ;;
  *) WORKTREE_TARGET_PATH="$DIR/$EXPECTED_TARGET" ;;
esac
if [ ! -f "$WORKTREE_TARGET_PATH" ] || [ -L "$WORKTREE_TARGET_PATH" ]; then
  echo "error: the expected target '$EXPECTED_TARGET' in $DIR is not a regular non-symlink file." >&2
  echo "Restore the target: $(restore_target_command)" >&2
  exit 1
fi

# What reaches a PR is the committed branch tip, not the working tree: a restore
# that is left uncommitted keeps the "distinct types on each side" conflict.
if git -C "$DIR" rev-parse --verify --quiet HEAD >/dev/null; then
  HEAD_ENTRY=$(git -C "$DIR" ls-tree --full-tree HEAD -- CLAUDE.md) || {
    echo "error: cannot read CLAUDE.md out of HEAD in $DIR" >&2
    exit 1
  }
  HEAD_PROBLEM=
  HEAD_NEEDS_TARGET=0
  HEAD_TARGET_ENTRY=$(git -C "$DIR" --literal-pathspecs ls-tree --full-tree HEAD -- "$EXPECTED_TARGET") || {
    echo "error: cannot read the expected target '$EXPECTED_TARGET' out of HEAD in $DIR" >&2
    exit 1
  }
  if ! tree_entry_is_regular_file "$HEAD_TARGET_ENTRY"; then
    HEAD_NEEDS_TARGET=1
  fi
  if [ -z "$HEAD_ENTRY" ]; then
    HEAD_PROBLEM="drops CLAUDE.md entirely"
  else
    HEAD_MODE=$(printf '%s\n' "$HEAD_ENTRY" | awk '{print $1}')
    HEAD_BLOB=$(printf '%s\n' "$HEAD_ENTRY" | awk '{print $3}')
    if [ "$HEAD_MODE" != 120000 ]; then
      HEAD_PROBLEM="still carries CLAUDE.md as a regular file (mode $HEAD_MODE)"
    else
      HEAD_TARGET=$(git -C "$DIR" cat-file -p "$HEAD_BLOB") || {
        echo "error: cannot read the CLAUDE.md symlink target out of HEAD in $DIR" >&2
        exit 1
      }
      if [ "$HEAD_TARGET" != "$EXPECTED_TARGET" ]; then
        HEAD_PROBLEM="carries CLAUDE.md as a symlink to '$HEAD_TARGET'"
      elif [ "$HEAD_NEEDS_TARGET" -eq 1 ]; then
        HEAD_PROBLEM="does not carry the expected target '$EXPECTED_TARGET' as a regular file"
      fi
    fi
  fi
  if [ -n "$HEAD_PROBLEM" ]; then
    echo "error: the working tree is fine, but your branch tip $HEAD_PROBLEM, while $BASE manages it as a symlink -> $EXPECTED_TARGET." >&2
    echo "That is what a PR would carry, so the 'distinct types on each side' conflict would come back." >&2
    echo "Commit the restored symlink: $(commit_branch_tip_command "$HEAD_NEEDS_TARGET")" >&2
    exit 1
  fi
fi

INDEX_UNMERGED=$(git -C "$DIR" --literal-pathspecs ls-files --unmerged -- CLAUDE.md) || {
  echo "error: cannot inspect the CLAUDE.md index entry in $DIR" >&2
  exit 1
}
if [ -n "$INDEX_UNMERGED" ]; then
  echo "error: CLAUDE.md has unmerged index entries in $DIR; resolve the index before reporting done." >&2
  echo "Restore it: $(restore_claude_command)" >&2
  exit 1
fi

INDEX_ENTRY=$(git -C "$DIR" --literal-pathspecs ls-files --stage -- CLAUDE.md) || {
  echo "error: cannot read the staged CLAUDE.md entry in $DIR" >&2
  exit 1
}
if [ -z "$INDEX_ENTRY" ]; then
  echo "error: CLAUDE.md is missing from the index in $DIR, so the next commit would drop the symlink." >&2
  echo "Restore it: $(restore_claude_command)" >&2
  exit 1
fi
INDEX_ENTRY_LINES=$(printf '%s\n' "$INDEX_ENTRY" | awk 'END {print NR}')
INDEX_MODE=$(printf '%s\n' "$INDEX_ENTRY" | awk '{print $1}')
INDEX_BLOB=$(printf '%s\n' "$INDEX_ENTRY" | awk '{print $2}')
INDEX_STAGE=$(printf '%s\n' "$INDEX_ENTRY" | awk '{print $3}')
if [ "$INDEX_ENTRY_LINES" -ne 1 ] || [ "$INDEX_MODE" != 120000 ] || [ "$INDEX_STAGE" != 0 ]; then
  echo "error: CLAUDE.md is not staged as the expected symlink in $DIR." >&2
  echo "Restore it: $(restore_claude_command)" >&2
  exit 1
fi
INDEX_TARGET=$(git -C "$DIR" cat-file -p "$INDEX_BLOB") || {
  echo "error: cannot read the staged CLAUDE.md symlink target in $DIR" >&2
  exit 1
}
if [ "$INDEX_TARGET" != "$EXPECTED_TARGET" ]; then
  echo "error: the staged CLAUDE.md symlink in $DIR points at '$INDEX_TARGET', not '$EXPECTED_TARGET'." >&2
  echo "Restore it: $(restore_claude_command)" >&2
  exit 1
fi

INDEX_TARGET_ENTRY=$(git -C "$DIR" --literal-pathspecs ls-files --stage -- "$EXPECTED_TARGET") || {
  echo "error: cannot read the staged target '$EXPECTED_TARGET' in $DIR" >&2
  exit 1
}
if [ -z "$INDEX_TARGET_ENTRY" ]; then
  echo "error: the expected target '$EXPECTED_TARGET' is missing from the index in $DIR." >&2
  echo "Stage the target in the index: $(stage_target_command)" >&2
  exit 1
fi
INDEX_TARGET_LINES=$(printf '%s\n' "$INDEX_TARGET_ENTRY" | awk 'END {print NR}')
INDEX_TARGET_MODE=$(printf '%s\n' "$INDEX_TARGET_ENTRY" | awk '{print $1}')
INDEX_TARGET_STAGE=$(printf '%s\n' "$INDEX_TARGET_ENTRY" | awk '{print $3}')
case "$INDEX_TARGET_MODE" in
  100*) ;;
  *)
    echo "error: the expected target '$EXPECTED_TARGET' is not staged as a regular file in $DIR." >&2
    echo "Stage the target in the index: $(stage_target_command)" >&2
    exit 1
    ;;
esac
if [ "$INDEX_TARGET_LINES" -ne 1 ] || [ "$INDEX_TARGET_STAGE" != 0 ]; then
  echo "error: the expected target '$EXPECTED_TARGET' has unmerged index entries in $DIR." >&2
  echo "Stage the target in the index: $(stage_target_command)" >&2
  exit 1
fi

INDEX_INTENT_TO_ADD=$(git -C "$DIR" --literal-pathspecs diff-files --name-only --diff-filter=A -- "$EXPECTED_TARGET") || {
  echo "error: cannot inspect the expected target's index state in $DIR" >&2
  exit 1
}
if [ -n "$INDEX_INTENT_TO_ADD" ]; then
  echo "error: the expected target '$EXPECTED_TARGET' is only intent-to-add in the index, so it would not be present in the next tree for $DIR." >&2
  echo "Stage the target in the index: $(stage_target_command)" >&2
  exit 1
fi

echo "ok: CLAUDE.md -> $EXPECTED_TARGET matches $BASE in $DIR (working tree and branch tip)"
