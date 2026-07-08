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
# against the primary checkout. The hook receives the worktree path, project
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
# Refuses to run when <worktree> resolves to <primary-root> - a defense-in-depth
# backstop for "never against the primary checkout" independent of the call
# site's own isolation assertion. Always returns 0.
fm_run_post_worktree_create_hook() {
  local config_dir=$1 primary_root=$2 wt=$3 project=$4 task_id=$5 kind=$6
  local hook="$config_dir/hooks/post-worktree-create" wt_real root_real status
  [ -f "$hook" ] && [ -x "$hook" ] || return 0
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  root_real=$(cd "$primary_root" 2>/dev/null && pwd -P) || root_real=$primary_root
  if [ "$wt_real" = "$root_real" ]; then
    echo "warning: post-worktree-create hook not run for $task_id: worktree is the primary checkout" >&2
    return 0
  fi
  FM_HOOK_WORKTREE="$wt" FM_HOOK_PROJECT="$project" FM_HOOK_TASK_ID="$task_id" FM_HOOK_KIND="$kind" \
    "$hook" "$wt" "$project" "$task_id" "$kind" || {
      status=$?
      echo "warning: post-worktree-create hook failed (exit $status) for $task_id; continuing spawn" >&2
    }
  return 0
}
