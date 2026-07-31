#!/usr/bin/env bash
# Validate a candidate runtime cwd for a detached Paseo root agent.
#
# The detached-paseo-agent skill is the only caller: it must never place an
# independent agent inside firstmate's operational home, so this script is the
# deterministic gate that decides whether a captain-supplied cwd is outside every
# firstmate-owned directory. Instructions alone are not enough for a safety
# boundary, so the refusal is enforced here rather than left to agent memory.
#
# Usage: fm-detached-cwd-check.sh <candidate-cwd>
#   Prints "SAFE <canonical-path>" and exits 0 when the candidate is a real
#   directory outside every firstmate-owned root.
#   Prints "UNSAFE: <reason>" to stderr and exits 1 otherwise, including a
#   missing, relative, unreadable, or ambiguous path. The caller must refuse the
#   request rather than rewrite the cwd on any non-zero exit.
#
# Forbidden roots (the candidate may not equal or sit inside any of them):
#   - FM_ROOT             the tracked firstmate code root
#   - FM_HOME             the effective operational home
#   - FM_HOME/projects    all registered project clones live here
#   - every worktree=      recorded in FM_HOME/state/*.meta (active task worktrees)
#
# Containment is decided by device+inode identity walked up the candidate's real
# ancestry, not by string prefix: this resolves symlinks, ".." traversal, and
# case-insensitive or otherwise alternate spellings to the same directory a
# forbidden root names. A candidate that merely CONTAINS firstmate (for example
# the parent of the home) is allowed - only a candidate inside firstmate is
# refused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

unsafe() {
  printf 'UNSAFE: %s\n' "$1" >&2
  exit 1
}

CANDIDATE=${1-}
[ -n "$CANDIDATE" ] || unsafe 'no candidate cwd given'
case "$CANDIDATE" in
  /*) ;;
  *) unsafe "candidate cwd must be an absolute path, got: $CANDIDATE" ;;
esac

# Portable "dev:inode" identity for an existing directory.
inode_key() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

# Canonical physical path of an existing directory, or empty on failure.
real_dir() {
  ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null
}

CANON=$(real_dir "$CANDIDATE")
[ -n "$CANON" ] || unsafe "candidate cwd does not resolve to a real directory: $CANDIDATE"

# Collect the device+inode identity of every firstmate-owned root that exists.
FORBIDDEN_KEYS=""
add_forbidden() {
  local dir=$1 canon key
  [ -n "$dir" ] || return 0
  canon=$(real_dir "$dir") || return 0
  [ -n "$canon" ] || return 0
  key=$(inode_key "$canon")
  [ -n "$key" ] || return 0
  FORBIDDEN_KEYS="$FORBIDDEN_KEYS$key
"
}

add_forbidden "$FM_ROOT"
add_forbidden "$FM_HOME"
add_forbidden "$FM_HOME/projects"

if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    while IFS= read -r line; do
      case "$line" in
        worktree=*) add_forbidden "${line#worktree=}" ;;
      esac
    done < "$meta"
  done
fi

# Fail closed if we could not identify a single forbidden root: without the
# firstmate roots there is nothing to protect the home with, so refuse.
[ -n "$FORBIDDEN_KEYS" ] || unsafe 'could not resolve any firstmate-owned root to compare against'

# Walk the candidate's real ancestry; refuse if any ancestor (including the
# candidate itself) is one of the forbidden roots by device+inode identity.
node="$CANON"
i=0
while [ "$i" -lt 100 ]; do
  key=$(inode_key "$node")
  if [ -n "$key" ] && printf '%s\n' "$FORBIDDEN_KEYS" | grep -Fxq "$key"; then
    unsafe "candidate cwd is inside a firstmate-owned directory: $CANON"
  fi
  parent=$(dirname "$node")
  [ "$parent" = "$node" ] && break
  node="$parent"
  i=$((i + 1))
done

printf 'SAFE %s\n' "$CANON"
exit 0
