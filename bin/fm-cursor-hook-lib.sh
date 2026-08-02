#!/usr/bin/env bash
# Shared ownership rules for the firstmate cursor turn-end hook.
#
# Cursor discovers hooks only at the worktree root's .cursor/hooks.json, a path a
# project may legitimately track, so fm-spawn and fm-teardown must agree on one
# ownership test: a hook file is firstmate's when it references our generated
# .cursor/fm-turn-end.sh script AND git does not track it. Spawn rewrites only
# its own hook (so a pooled worktree carrying a stale one is re-armed instead of
# left signalling a dead task); teardown removes only its own.

FM_CURSOR_HOOK_EXCLUDES='^\.cursor/(hooks\.json|fm-turn-end\.sh)$'

fm_cursor_hook_is_ours() {
  local wt=$1
  [ -n "$wt" ] || return 1
  [ -f "$wt/.cursor/hooks.json" ] || return 1
  grep -qF '.cursor/fm-turn-end.sh' "$wt/.cursor/hooks.json" 2>/dev/null || return 1
  ! git -C "$wt" ls-files --error-unmatch -- '.cursor/hooks.json' >/dev/null 2>&1
}

# The exclude entries fm-spawn adds for the cursor hook land in the clone-wide
# info/exclude, shared by every worktree and never pruned by git, so leaving
# '.cursor/hooks.json' behind would permanently untrack a project's own hook
# file. Drop both entries once no worktree of this clone still carries a
# firstmate hook script.
fm_cursor_hook_release_exclude() {
  local wt=$1 excl line other= tmp rc
  [ -n "$wt" ] || return 0
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  case "$excl" in
    '') return 0 ;;
    /*) ;;
    *) excl="$wt/$excl" ;;
  esac
  [ -f "$excl" ] || return 0
  grep -qE "$FM_CURSOR_HOOK_EXCLUDES" "$excl" || return 0
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) other=${line#worktree } ;;
      *) continue ;;
    esac
    [ ! -e "$other/.cursor/fm-turn-end.sh" ] || return 0
  done <<EOF
$(git -C "$wt" worktree list --porcelain 2>/dev/null)
EOF
  tmp="$excl.fm.$$"
  rc=0
  grep -vE "$FM_CURSOR_HOOK_EXCLUDES" "$excl" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -le 1 ]; then
    mv "$tmp" "$excl"
  else
    rm -f "$tmp"
  fi
  return 0
}
