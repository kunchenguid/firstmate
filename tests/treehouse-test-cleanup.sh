#!/usr/bin/env bash
# Register acquired pools before containment failures invoke suite cleanup.
# Call remember_meta_worktree directly; REMEMBERED_WORKTREE returns its result.

record_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  case "$wt" in
    "$TREEHOUSE_ROOT"/*) : ;;
    *) fail "worktree escaped the test Treehouse root: $wt" ;;
  esac
  return 0
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" | cut -d= -f2-)
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
  # Result read by the caller after this direct invocation.
  # shellcheck disable=SC2034
  REMEMBERED_WORKTREE=$wt
  case "$wt" in
    "$TREEHOUSE_ROOT"/*) : ;;
    *) fail "worktree escaped the test Treehouse root: $wt" ;;
  esac
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  printf '%s' "$wt"
}
