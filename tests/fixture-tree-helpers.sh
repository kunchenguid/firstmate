#!/usr/bin/env bash
# tests/fixture-tree-helpers.sh - remove a fixture tree completely, including
# the launch directories its real spawns staged outside it.
#
# Source this before a suite's cleanup can run:
#   # shellcheck source=tests/fixture-tree-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixture-tree-helpers.sh"
#
# The real fm-spawn.sh leaves each state/<id>.git-hooks strip directory
# read-only on purpose (bin/fm-git-strip-ai-trailers.sh), and only fm-teardown.sh
# restores write permission for the task it tears down. A fixture home that
# still holds one when the suite ends cannot be removed by a plain `rm -rf`,
# so every run would leak its temp tree. tests/lib.sh and
# tests/herdr-test-safety.sh source this for every suite that uses them.
# tests/fm-test-fixtures.test.sh is the regression.

# fm_test_remove_tree <dir>: restore owner write permission on the directories
# of exactly <dir>, then remove it. A symlink is removed without following it,
# so permissions outside the tree are never changed. Returns rm's status.
fm_test_remove_tree() {
  local dir=$1
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    find "$dir" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  fi
  rm -rf "$dir"
}

# fm_test_home_hash <home>: print the sha256 of the physical <home> path, the
# home token fm-spawn.sh puts in each launch directory name /tmp/fm-<id>+<hash>.
fm_test_home_hash() {
  local home hash
  home=$(cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$home" | shasum -a 256 | awk '{print $1}')
  else
    hash=$(printf '%s' "$home" | sha256sum | awk '{print $1}')
  fi
  case "$hash" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  printf '%s\n' "$hash"
}

# fm_test_remove_spawn_launch_dirs <fixture-root>: remove every launch
# directory /tmp/fm-<id>+<sha256 of the physical home path> that the real
# fm-spawn.sh staged outside the fixture for a Firstmate home under
# <fixture-root> (any directory with a state/ child, including the root), so a
# task the suite never tore down, or whose record it deleted, still leaves
# nothing behind. It is the same name fm-teardown.sh retires, and the home hash
# keeps every other home's launch directories out of reach. The per-task
# /tmp/fm-<id> root is not home-scoped, so it is not this helper's to remove;
# fm-spawn.sh's own cleanup owns it.
# Call this before removing <fixture-root>, because the home paths must resolve.
fm_test_remove_spawn_launch_dirs() {
  local root=$1 home hash dir
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    hash=$(fm_test_home_hash "$home") || continue
    while IFS= read -r dir; do
      if [ -n "$dir" ]; then
        fm_test_remove_tree "$dir"
      fi
    done <<EOF_DIRS
$(find /tmp/ -maxdepth 1 -type d -name "fm-*+$hash" 2>/dev/null)
EOF_DIRS
  done <<EOF_HOMES
$(find "$root" -type d -name state -prune -exec dirname {} \; 2>/dev/null)
EOF_HOMES
  return 0
}
