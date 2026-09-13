#!/usr/bin/env bash
# fm-treehouse-pool-lib.sh - point a freshly cloned project's treehouse
# worktree pool at a root private to the home that cloned it.
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
#
# The root is derived from the home's absolute path and lives in the machine
# state directory, outside the home worktree and every other git repository:
# treehouse keeps its pool out of git by appending the pool path to the
# .gitignore of whichever repository encloses {root}/.treehouse, so a root
# inside the home (itself a firstmate clone) would leave that home dirty and
# stop its fast-forward updates.

# fm_treehouse_pool_root <home>
# Prints the stable, collision-free pool root for <home>.
fm_treehouse_pool_root() {
  local home=$1 base hash
  base="${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/treehouse-pools"
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$home" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$home" | sha256sum | awk '{print $1}')
  else
    hash=$(printf '%s' "$home" | cksum | awk '{printf "%08x%08x", $1, $2}')
  fi
  printf '%s/%s\n' "$base" "$hash"
}

# fm_treehouse_configure_pool_root <clone-dir> <home>
# Points <clone-dir>'s treehouse pool at <home>'s own pool root and excludes
# the generated file locally so the clone stays clean. A project that tracks
# its own treehouse.toml keeps it: the seed warns and continues instead of
# aborting.
fm_treehouse_configure_pool_root() {
  local clone=$1 home=$2 toml exclude pool_root
  toml="$clone/treehouse.toml"
  if git -C "$clone" ls-files --error-unmatch treehouse.toml >/dev/null 2>&1; then
    echo "warning: project $(basename "$clone") keeps its own treehouse pool configuration in treehouse.toml, so this home's per-home pool root was not applied; worker spawns from this home may be refused if that configuration resolves to a pool shared with another home. Give that configuration a root unique to this home to avoid the collision." >&2
    return 0
  fi
  pool_root=$(fm_treehouse_pool_root "$home")
  printf 'root = "%s"\n' "$pool_root" > "$toml.tmp.$$"
  mv -f -- "$toml.tmp.$$" "$toml"
  exclude="$clone/.git/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  grep -qxF '/treehouse.toml' "$exclude" 2>/dev/null || printf '/treehouse.toml\n' >> "$exclude"
}
