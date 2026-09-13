#!/usr/bin/env bash
# fm-treehouse-pool-lib.sh - point a freshly cloned project's treehouse
# worktree pool at the home that cloned it.
#
# WHY: treehouse names a project's pool from a hash of the origin URL alone,
# placed under its configured root (default $HOME). Two firstmate homes that
# each clone the same origin therefore collide on one pool, and every
# worktree in it stays linked to whichever clone created it first - so a
# secondmate spawning work in a project its parent home also clones gets
# handed a worktree of the PARENT's clone. fm-spawn.sh's pre-registration
# guard (bin/fm-claude-trust.sh, bin/fm-agy-trust.sh) already catches and
# refuses that mismatch; this removes the collision instead of relaxing the
# guard. Treehouse reads treehouse.toml from a project's own repository root
# and honors a `root` key there ({root}/.treehouse/ instead of $HOME).

# fm_treehouse_configure_pool_root <clone-dir> <pool-root>
# Points <clone-dir>'s treehouse pool at <pool-root> (an absolute path) and
# excludes the generated file locally so the clone stays clean.
fm_treehouse_configure_pool_root() {
  local clone=$1 pool_root=$2 toml exclude
  toml="$clone/treehouse.toml"
  if git -C "$clone" ls-files --error-unmatch treehouse.toml >/dev/null 2>&1; then
    echo "error: $clone tracks its own treehouse.toml; refusing to overwrite a project-owned config" >&2
    return 1
  fi
  printf 'root = "%s"\n' "$pool_root" > "$toml.tmp.$$"
  mv -f -- "$toml.tmp.$$" "$toml"
  exclude="$clone/.git/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  grep -qxF '/treehouse.toml' "$exclude" 2>/dev/null || printf '/treehouse.toml\n' >> "$exclude"
}
