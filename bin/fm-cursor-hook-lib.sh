#!/usr/bin/env bash
# Shared ownership rules for the firstmate cursor turn-end hook, plus the
# git-exclude bookkeeping that carries it.
#
# Cursor discovers hooks only at the worktree root's .cursor/hooks.json, a path a
# project may legitimately track, so fm-spawn and fm-teardown must agree on one
# ownership test: a hook file is firstmate's when it references our generated
# .cursor/fm-turn-end.sh script AND git does not track it. The script is
# firstmate's only when that hook matches, git does not track the script, and
# the script carries a firstmate turn-end signal. Spawn rewrites only its own
# hook (so a pooled worktree carrying a stale one is re-armed instead of left
# signalling a dead task); teardown removes only its own.
#
# info/exclude is clone-wide and developer-owned. Firstmate's cursor entries go
# in as one self-identifying block and only that exact block is ever removed, so
# a hand-written '.cursor/hooks.json' exclude is neither adopted nor dropped.
# Every writer holds fm_git_exclude_lock across its read-modify-write, because an
# unsynchronized append and rewrite of that shared file lose each other's lines.

FM_CURSOR_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_CURSOR_HOOK_EXCLUDE_MARKER='# firstmate cursor turn-end hook (auto-managed)'

fm_cursor_hook_is_ours() {
  local wt=$1
  [ -n "$wt" ] || return 1
  [ -f "$wt/.cursor/hooks.json" ] || return 1
  grep -qF '.cursor/fm-turn-end.sh' "$wt/.cursor/hooks.json" 2>/dev/null || return 1
  ! git -C "$wt" ls-files --error-unmatch -- '.cursor/hooks.json' >/dev/null 2>&1
}

fm_cursor_hook_script_is_ours() {
  local wt=$1
  [ -n "$wt" ] || return 1
  [ -e "$wt/.cursor/fm-turn-end.sh" ] || return 1
  fm_cursor_hook_is_ours "$wt" || return 1
  grep -qF 'Firstmate cursor turn-end signal' "$wt/.cursor/fm-turn-end.sh" 2>/dev/null || return 1
  ! git -C "$wt" ls-files --error-unmatch -- '.cursor/fm-turn-end.sh' >/dev/null 2>&1
}

# Absolute path of the clone-wide exclude file; --git-path answers relative to
# the worktree for a plain checkout and absolute for a linked worktree.
fm_git_exclude_file() {
  local wt=$1 excl
  [ -n "$wt" ] || return 1
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null) || return 1
  case "$excl" in
    '') return 1 ;;
    /*) ;;
    *) excl="$wt/$excl" ;;
  esac
  printf '%s\n' "$excl"
}

fm_git_exclude_lock() {
  local excl=$1
  if ! declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_CURSOR_HOOK_LIB_DIR/fm-wake-lib.sh"
  fi
  declare -F fm_lock_acquire_wait >/dev/null 2>&1 || return 1
  fm_lock_acquire_wait "$excl.fm-lock"
}

fm_git_exclude_unlock() {
  declare -F fm_lock_release >/dev/null 2>&1 || return 0
  fm_lock_release "$1.fm-lock"
}

# Append each pattern that is not already present. Safe without the lock (a
# short append is atomic), but taken anyway so a concurrent block rewrite
# cannot read a stale copy of the file.
fm_git_exclude_add() {
  local excl=$1 rel
  shift
  mkdir -p "$(dirname "$excl")"
  fm_git_exclude_lock "$excl" || true
  for rel in "$@"; do
    grep -qxF "$rel" "$excl" 2>/dev/null || printf '%s\n' "$rel" >> "$excl"
  done
  fm_git_exclude_unlock "$excl"
}

fm_cursor_hook_claim_exclude() {
  local wt=$1 excl
  excl=$(fm_git_exclude_file "$wt") || return 0
  mkdir -p "$(dirname "$excl")"
  fm_git_exclude_lock "$excl" || true
  if ! grep -qxF "$FM_CURSOR_HOOK_EXCLUDE_MARKER" "$excl" 2>/dev/null; then
    printf '%s\n.cursor/hooks.json\n.cursor/fm-turn-end.sh\n' "$FM_CURSOR_HOOK_EXCLUDE_MARKER" >> "$excl"
  fi
  fm_git_exclude_unlock "$excl"
}

# 0 when a worktree of this clone still carries a firstmate hook script OR the
# worktree list cannot be read; 1 only when provably none does. Fails closed:
# forced child cleanup runs against worktrees whose processes were just killed,
# and an unreadable list is not proof that no live hook remains.
fm_cursor_hook_clone_holds_hook() {
  local wt=$1 worktrees line other=
  worktrees=$(git -C "$wt" worktree list --porcelain 2>/dev/null) || return 0
  [ -n "$worktrees" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) other=${line#worktree } ;;
      *) continue ;;
    esac
    ! fm_cursor_hook_script_is_ours "$other" || return 0
  done <<EOF
$worktrees
EOF
  return 1
}

fm_cursor_hook_strip_exclude_block() {
  awk -v marker="$FM_CURSOR_HOOK_EXCLUDE_MARKER" '
    $0 == marker { skip = 2; next }
    skip > 0 && ($0 == ".cursor/hooks.json" || $0 == ".cursor/fm-turn-end.sh") { skip--; next }
    { skip = 0; print }
  ' "$1"
}

fm_cursor_hook_release_exclude() {
  local wt=$1 excl tmp
  excl=$(fm_git_exclude_file "$wt") || return 0
  [ -f "$excl" ] || return 0
  grep -qxF "$FM_CURSOR_HOOK_EXCLUDE_MARKER" "$excl" || return 0
  fm_git_exclude_lock "$excl" || return 0
  if ! fm_cursor_hook_clone_holds_hook "$wt"; then
    tmp="$excl.fm.$$"
    if fm_cursor_hook_strip_exclude_block "$excl" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$excl"
    else
      rm -f "$tmp"
    fi
  fi
  fm_git_exclude_unlock "$excl"
  return 0
}
