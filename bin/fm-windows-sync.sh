#!/usr/bin/env bash
# Sync Windows-side clones listed in config/windows-clones.json after a merge or
# fleet-sync fast-forward. For each entry with auto_pull=true, pulls the project's
# default branch into the Windows clone. Safe when the Windows filesystem is not
# mounted (warns and continues) and when the clone has local changes (stashes
# before pull, pops after). A stash-pop conflict is warned but not treated as a
# failure because the pull itself succeeded.
#
# Reads the firstmate project clone under projects/ to determine the default branch,
# so a project must be registered and cloned before its Windows clone can sync.
#
# Usage: fm-windows-sync.sh [<project-name>]
#   With no argument, syncs all clones with auto_pull=true.
#   With a project name, syncs only that clone.
#
# Requires: jq, git
# Exit codes: 0 always (best-effort; per-clone failures are reported but do not
# stop other clones).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="$FM_HOME/config/windows-clones.json"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() {
  echo "usage: fm-windows-sync.sh [<project-name>]" >&2
  echo "  Sync Windows-side clones from config/windows-clones.json." >&2
  echo "  With no argument, syncs all auto_pull=true entries." >&2
  echo "  With a project name, syncs only that entry." >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ $# -le 1 ] || { usage; exit 1; }

if [ ! -f "$CONFIG" ]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "windows-sync: skipped: jq not found" >&2
  exit 0
fi

default_branch_for_project() {
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

sync_one() {
  local name=$1 windows_path default_branch proj_dir pull_output pull_rc
  local stash_output stash_rc pop_rc

  windows_path=$(jq -r --arg k "$name" '.[$k].windows_path // empty' "$CONFIG" 2>/dev/null) || true
  if [ -z "$windows_path" ]; then
    echo "windows-sync: $name: skipped: no windows_path configured"
    return 0
  fi

  auto_pull=$(jq -r --arg k "$name" '.[$k].auto_pull // false' "$CONFIG" 2>/dev/null) || true
  if [ "$auto_pull" != "true" ]; then
    return 0
  fi

  if [ ! -d "$windows_path" ]; then
    echo "windows-sync: $name: skipped: $windows_path not found (Windows filesystem may not be mounted)"
    return 0
  fi

  if [ ! -d "$windows_path/.git" ]; then
    echo "windows-sync: $name: skipped: $windows_path is not a git repository"
    return 0
  fi

  proj_dir="$PROJECTS/$name"
  if [ -d "$proj_dir" ]; then
    default_branch=$(default_branch_for_project "$proj_dir") || default_branch=""
  else
    default_branch=""
  fi

  if [ -z "$default_branch" ]; then
    default_branch=$(default_branch_for_project "$windows_path") || default_branch=""
  fi

  if [ -z "$default_branch" ]; then
    echo "windows-sync: $name: failed: cannot determine default branch"
    return 0
  fi

  pull_rc=0
  pull_output=$(git -C "$windows_path" pull origin "$default_branch" 2>&1) || pull_rc=$?

  if [ "$pull_rc" -eq 0 ]; then
    echo "windows-sync: $name: ok"
    return 0
  fi

  if printf '%s\n' "$pull_output" | grep -q "Your local changes"; then
    stash_rc=0
    stash_output=$(git -C "$windows_path" stash push -u -m "fm-windows-sync: auto-stash before pull" 2>&1) || stash_rc=$?
    if [ "$stash_rc" -ne 0 ]; then
      echo "windows-sync: $name: failed: stash failed: $(printf '%s' "$stash_output" | head -1)"
      return 0
    fi

    pull_rc=0
    pull_output=$(git -C "$windows_path" pull origin "$default_branch" 2>&1) || pull_rc=$?
    if [ "$pull_rc" -ne 0 ]; then
      echo "windows-sync: $name: failed: pull failed after stash: $(printf '%s' "$pull_output" | head -1)"
      return 0
    fi

    pop_rc=0
    git -C "$windows_path" stash pop >/dev/null 2>&1 || pop_rc=$?
    if [ "$pop_rc" -ne 0 ]; then
      echo "windows-sync: $name: ok (pull succeeded, but stash pop had conflicts - resolve manually)"
      return 0
    fi

    echo "windows-sync: $name: ok"
    return 0
  fi

  echo "windows-sync: $name: failed: $(printf '%s' "$pull_output" | head -1)"
  return 0
}

FILTER="${1:-}"

if [ -n "$FILTER" ]; then
  if ! jq -e --arg k "$FILTER" 'has($k)' "$CONFIG" >/dev/null 2>&1; then
    echo "windows-sync: $FILTER: skipped: not in windows-clones.json"
    exit 0
  fi
  sync_one "$FILTER"
  exit 0
fi

projects=$(jq -r 'keys[]' "$CONFIG" 2>/dev/null) || {
  echo "windows-sync: skipped: cannot parse $CONFIG" >&2
  exit 0
}

while IFS= read -r name; do
  [ -n "$name" ] || continue
  sync_one "$name"
done <<EOF
$projects
EOF
