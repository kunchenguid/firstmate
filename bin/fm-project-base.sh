#!/usr/bin/env bash
# Resolve a project's DEVELOPMENT BRANCH - the branch a task worktree must start
# from and the branch a clone must be kept current against.
# Prints the branch name, or nothing when the project declares none (callers then
# fall back to the repository's own default branch).
#
# Usage: fm-project-base.sh <clone-or-worktree-dir> [<project-name>]
#
# Resolution order, first hit wins:
#   1. .firstmate-base in the given working tree.
#   2. .firstmate-base on a remote-tracking or local branch, most recently committed first.
#   3. base=<branch> in this home's private data/projects.md registry, when a
#      project name is given.
#
# WHY THE FILE COMES FIRST. The captain's ruling is that the development branch
# is stored IN THE REPO, because a value in one home's private registry tells no
# other home anything: a second mate that clones the same project, or a freshly
# provisioned home with no registry entry yet, reads the committed file and gets
# the same answer the main home has. The registry tier remains only as the
# fallback for a project that has not adopted the file yet.
#
# WHY THE REF SCAN. A project that develops on develop typically lands the file
# on develop, and its abandoned default branch never receives it - the very shape
# that makes this bug expensive. Reading only the checked-out tree would miss it
# and silently fall back to the stale default. Ceiling: when two branches carry
# DIFFERENT values the most recent commit wins; that is a heuristic, not a merge,
# and a project needing per-branch bases would need a real answer instead.
#
# The file holds one branch name and nothing else:
#   echo develop > .firstmate-base
# Firstmate never writes it - AGENTS.md hard rule 1 - so it is landed through the
# project's own delivery path, or by firstmate's guarded initialization when the
# project is created. A malformed value is ignored rather than passed to git.
set -eu

DIR=${1:?usage: fm-project-base.sh <clone-or-worktree-dir> [<project-name>]}
NAME=${2:-}
FILE=.firstmate-base

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# A branch name reaching git from a repository file is a trust boundary: reject
# anything that is not one plain ref path, so no value can become an option or a
# revision expression.
emit_if_valid() {  # <value>
  local v=$1
  case $v in
    ''|-*|*' '*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  git -C "$DIR" check-ref-format --branch "$v" >/dev/null 2>&1 || return 1
  printf '%s\n' "$v"
}

read_first_line() {  # reads stdin
  head -n 1 | tr -d '\r' | awk '{$1=$1; print}'
}

[ -d "$DIR" ] || exit 0

if [ -f "$DIR/$FILE" ] && [ ! -L "$DIR/$FILE" ]; then
  if emit_if_valid "$(read_first_line < "$DIR/$FILE")"; then
    exit 0
  fi
fi

if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case $ref in */HEAD) continue ;; esac
    value=$(git -C "$DIR" show "$ref:$FILE" 2>/dev/null | read_first_line) || continue
    if emit_if_valid "$value"; then
      exit 0
    fi
  done < <(git -C "$DIR" for-each-ref --sort=-committerdate --format='%(refname)' refs/remotes refs/heads 2>/dev/null || true)
fi

if [ -n "$NAME" ]; then
  recorded=$("$FM_ROOT/bin/fm-project-mode.sh" --base "$NAME" 2>/dev/null || true)
  [ -z "$recorded" ] || emit_if_valid "$recorded" || true
fi
exit 0
