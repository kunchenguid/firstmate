# shellcheck shell=bash
# Shared predicates for treehouse-backed firstmate pool worktrees.
#
# A pool backing clone may legitimately carry an untracked root-level
# treehouse.toml, because that file is the pool's local treehouse config.
# Treat only that lone porcelain entry as clean.
# Every other porcelain entry is real uncommitted work.
#
# Every slot lifecycle path that judges a pool worktree must agree on this, or a
# slot that spawn accepted becomes a slot teardown/rehome refuses - which strands
# its treehouse lease until someone forces it. Callers that carry their own
# harness-noise allowlist filter through fm_pool_ignorable_porcelain_filter on
# top of it rather than restating the exemption.

fm_pool_ignorable_porcelain_filter() {  # porcelain lines on stdin
  grep -vFx '?? treehouse.toml' || true
}

fm_pool_real_porcelain() {  # <repo>
  local repo=$1 out
  out=$(git -C "$repo" status --porcelain 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | fm_pool_ignorable_porcelain_filter
}

fm_pool_worktree_clean() {  # <repo>
  local repo=$1 real
  real=$(fm_pool_real_porcelain "$repo") || return 1
  [ -z "$real" ]
}

fm_pool_first_real_porcelain_line() {  # <repo>
  local repo=$1 real
  real=$(fm_pool_real_porcelain "$repo") || return 1
  [ -n "$real" ] || return 1
  printf '%s\n' "${real%%$'\n'*}"
}
