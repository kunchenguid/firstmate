# shellcheck shell=bash
# Treehouse path-spelling helpers. Usage: . bin/fm-treehouse-lib.sh
# Requires bin/fm-path-lib.sh to be sourced first (fm_same_physical_dir).
#
# `treehouse return <path>` matches its argument against the pool's recorded
# worktree paths without resolving symlinks, and treehouse records the spelling
# it derived from its own $HOME. On a host whose home directory is a symlink -
# /home/x -> /data00/home/x - the pool records
# /home/x/.treehouse/<pool>/1/<repo>, while firstmate canonicalizes every path
# it stores with `pwd -P` and hands back
# /data00/home/x/.treehouse/<pool>/1/<repo>. Every return then fails with
# "worktree ... is not managed by treehouse", so every task teardown and every
# leased-home release aborts on that host.
#
# Reproduced directly on treehouse v2.1.0 (2026-07-28, Linux) with a scratch
# pool under a symlinked HOME: `treehouse return --force <physical path>`
# printed "worktree <path> is not managed by treehouse" while
# `treehouse return --force <recorded symlinked path>` returned it cleanly.
#
# The fix keeps firstmate's own records physical - comparisons, ancestor checks,
# and unlanded-work guards all stay on one canonical form - and translates ONLY
# at the boundary where a path is handed to treehouse. The pool state file is
# the same record `treehouse return` itself consults, so treehouse's spelling is
# the authority rather than any guess about which alias is "right".
#
# Safety: a candidate read out of the state file is used only after
# fm_same_physical_dir proves it names the SAME directory object (device+inode).
# A malformed, stale, or unrelated entry can therefore never redirect a return
# to a different directory; it is discarded and the caller keeps its own path,
# which is exactly the behavior that existed before this translation.

# fm_treehouse_pool_state_file <dir>: print the pool state file that would record
# <dir>. A pooled worktree lives at <pool>/<name>/<repo> and the state file sits
# at <pool>/treehouse-state.json, so the pool directory is <dir>/../.. (verified
# against a real pool created by treehouse v2.1.0). Fails when that directory
# does not exist.
fm_treehouse_pool_state_file() {
  local dir=$1 pool
  [ -n "$dir" ] || return 1
  pool=$(cd "$dir/../.." 2>/dev/null && pwd -P) || return 1
  printf '%s/treehouse-state.json\n' "$pool"
}

# fm_treehouse_state_paths <state-file>: print each recorded worktree path, one
# per line. Treehouse writes the state indented with one field per line, so every
# entry is its own "path": "<value>" line.
#
# Deliberately jq-free: teardown and seed rollback must not gain a new required
# tool for a path fixup. A path whose JSON encoding contains an escape sequence
# (a quote, a backslash, or one of the \uXXXX forms Go emits for < > &) is read
# back mangled and then rejected by the caller's device+inode check, leaving the
# untranslated path in place. That is a missed translation, never a wrong one.
fm_treehouse_state_paths() {
  local state=$1
  [ -n "$state" ] && [ -f "$state" ] || return 1
  sed -n 's/^[[:space:]]*"path"[[:space:]]*:[[:space:]]*"//p' "$state" \
    | sed 's/",*[[:space:]]*$//'
}

# fm_treehouse_recorded_path <dir>: print the spelling treehouse recorded for the
# directory <dir> names, or fail when <dir> is not in a treehouse pool, the pool
# state is unreadable, or no recorded entry names the same directory object.
# Callers pass the result to treehouse and fall back to their own path on failure.
fm_treehouse_recorded_path() {
  local dir=$1 state candidate
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  state=$(fm_treehouse_pool_state_file "$dir") || return 1
  [ -f "$state" ] || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if fm_same_physical_dir "$candidate" "$dir"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$(fm_treehouse_state_paths "$state")
EOF
  return 1
}

# fm_treehouse_return_path <dir>: the path to hand `treehouse return`. Prefers
# treehouse's own recorded spelling and falls back to <dir> unchanged, so a
# non-pooled directory, an older pool layout, or an unreadable state file behaves
# exactly as it did before this translation existed.
fm_treehouse_return_path() {
  local dir=$1 recorded
  if recorded=$(fm_treehouse_recorded_path "$dir"); then
    printf '%s\n' "$recorded"
    return 0
  fi
  printf '%s\n' "$dir"
}
