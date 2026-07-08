#!/usr/bin/env bash
# General spawn extension points for fm-spawn.sh.
#
# The post-worktree-create hook lets an operator run a local, gitignored script
# right after fm-spawn has created a task's worktree - or a secondmate's home -
# and asserted it is a genuine isolated worktree, for every task kind (crewmate,
# scout, secondmate). firstmate ships no hook, so an absent hook is a complete
# no-op with zero behavior change for anyone not using it.
#
# The hook is purely additive fleet-local wiring: it never gates a spawn (a hook
# that errors is warned and swallowed, and the spawn continues) and it never runs
# against the primary checkout. A hang cannot gate a launch either: the hook
# runs under a time budget of FM_HOOK_TIMEOUT seconds (default 120) via 'timeout'
# or 'gtimeout', and a timed-out hook is warned and skipped exactly like a
# failing one. When neither binary exists the hook runs unbounded with a stderr
# warning - a missing timeout binary never fails the spawn.
# The hook receives the worktree path, project
# name, task id, and kind as both positional arguments ($1..$4) and environment
# (FM_HOOK_WORKTREE, FM_HOOK_PROJECT, FM_HOOK_TASK_ID, FM_HOOK_KIND), so a hook
# can read whichever is convenient. For a secondmate spawn the worktree is the
# secondmate home and the project name is that home's directory name; a hook
# tells the cases apart with FM_HOOK_KIND.
#
# The full contract lives in docs/configuration.md ("Post-worktree-create hook");
# docs/examples/post-worktree-create is a runnable sample.

# fm_run_post_worktree_create_hook <config-dir> <primary-root> <worktree> <project> <task-id> <kind>
# Run <config-dir>/hooks/post-worktree-create when it exists and is executable.
# A no-op (return 0) when it is absent. Non-fatal: a hook that exits non-zero is
# warned to stderr and this function still returns 0 so the spawn continues.
# Bounded: the hook runs under 'timeout' (or macOS 'gtimeout') with a budget of
# FM_HOOK_TIMEOUT seconds (default 120), and a timed-out hook is warned and
# skipped like a failing one, so a hang cannot gate a launch either. When
# neither timeout binary exists the hook runs unbounded after a stderr warning;
# a missing timeout binary never fails the spawn.
# Refuses to run when <worktree> resolves to <primary-root> - a defense-in-depth
# backstop for "never against the primary checkout" independent of the call
# site's own isolation assertion. Always returns 0.
fm_run_post_worktree_create_hook() {
  local config_dir=$1 primary_root=$2 wt=$3 project=$4 task_id=$5 kind=$6
  local hook="$config_dir/hooks/post-worktree-create" wt_real root_real hook_status
  local budget="${FM_HOOK_TIMEOUT:-120}" timeout_bin=""
  [ -f "$hook" ] && [ -x "$hook" ] || return 0
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  root_real=$(cd "$primary_root" 2>/dev/null && pwd -P) || root_real=$primary_root
  if [ "$wt_real" = "$root_real" ]; then
    echo "warning: post-worktree-create hook not run for $task_id: worktree is the primary checkout" >&2
    return 0
  fi
  case "$budget" in
    ''|*[!0-9]*) budget=120 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  fi
  hook_status=0
  if [ -n "$timeout_bin" ]; then
    FM_HOOK_WORKTREE="$wt" FM_HOOK_PROJECT="$project" FM_HOOK_TASK_ID="$task_id" FM_HOOK_KIND="$kind" \
      "$timeout_bin" "$budget" "$hook" "$wt" "$project" "$task_id" "$kind" || hook_status=$?
  else
    echo "warning: neither 'timeout' nor 'gtimeout' on PATH; post-worktree-create hook for $task_id runs unbounded" >&2
    FM_HOOK_WORKTREE="$wt" FM_HOOK_PROJECT="$project" FM_HOOK_TASK_ID="$task_id" FM_HOOK_KIND="$kind" \
      "$hook" "$wt" "$project" "$task_id" "$kind" || hook_status=$?
  fi
  if [ "$hook_status" -ne 0 ]; then
    if [ -n "$timeout_bin" ] && [ "$hook_status" -eq 124 ]; then
      echo "warning: post-worktree-create hook timed out after ${budget}s for $task_id; continuing spawn" >&2
    else
      echo "warning: post-worktree-create hook failed (exit $hook_status) for $task_id; continuing spawn" >&2
    fi
  fi
  return 0
}
