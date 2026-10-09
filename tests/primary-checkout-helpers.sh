#!/usr/bin/env bash
# Temporary primary checkouts for suites that run supervisor-only entrypoints.
#
# Supervisor-only entrypoints trust only the checkout that contains them, and a
# linked crew/scout worktree is never that checkout (bin/fm-primary-scope-lib.sh).
# A suite run from a linked worktree therefore runs against a disposable plain
# clone of the same commit carrying the same uncommitted and untracked files, so
# "$ROOT/bin/..." is always the real supervisor copy in a primary checkout.
# tests/lib.sh sources this file; standalone suites source it directly and own
# the cleanup of the base directory they pass in. No side effects on source.

fm_test_plain_checkout() {  # <dir>
  local git_dir git_common_dir
  git_dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || return 1
  git_common_dir=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$git_common_dir" ]
}

# Make <dir> a plain primary checkout, for a fixture that installs copied
# supervisor scripts under <dir>/bin.
fm_test_primary_checkout() {  # <dir>
  local dir=$1
  [ -f "$dir/AGENTS.md" ] || cp "$ROOT/AGENTS.md" "$dir/AGENTS.md" || return 1
  fm_test_plain_checkout "$dir" && return 0
  git init --quiet "$dir"
}

# Print a plain primary copy of <source-checkout> staged under the existing,
# caller-owned <base> directory.
fm_test_primary_snapshot() {  # <source-checkout> <base>
  local src=$1 base=$2 snap head patch
  snap="$base/firstmate"
  patch="$base/worktree.patch"
  head=$(git -C "$src" rev-parse HEAD) || return 1
  git clone --quiet --shared --no-checkout "$src" "$snap" || return 1
  git -C "$snap" checkout --quiet --detach "$head" || return 1
  git -C "$src" diff --binary HEAD > "$patch" || return 1
  if [ -s "$patch" ]; then
    git -C "$snap" apply --whitespace=nowarn "$patch" || return 1
  fi
  (cd "$src" && git ls-files -z -o --exclude-standard | tar --null -T - -cf -) \
    | tar -xf - -C "$snap" || return 1
  printf '%s\n' "$snap"
}
