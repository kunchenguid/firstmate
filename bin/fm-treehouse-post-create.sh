#!/usr/bin/env bash
# Treehouse post_create hook: run a firstmate per-project worktree setup
# script (data/<project>-setup.sh) when a worktree is provisioned or reset.
#
# Treehouse >= v1.8.0 fires post_create in the worktree directory, right
# before `treehouse get` hands the worktree over. That is the natural place
# to install dependencies, build, or copy env files so a crewmate agent
# launches into a ready worktree. Treehouse itself knows nothing about
# firstmate; this hook bridges the two by locating firstmate's operational
# directories from its own location (it lives in firstmate's bin/).
#
# Wiring (machine-level, one-time): add to ~/.config/treehouse/config.toml
#   [hooks]
#   post_create = ["<absolute path to this script>"]
# Treehouse ignores repo-level treehouse.toml hooks for safety, so the user
# config is the only place this can live.
#
# Behavior:
#   - project name = basename of the worktree directory, which matches the
#     repo basename and the data/projects.md registry convention (projects
#     are cloned as projects/<repo-basename>). Before running setup, the hook
#     verifies this worktree belongs to that firstmate project clone.
#   - firstmate home = $FM_HOME if set, else derived from this script's
#     location (../ from bin/). Secondmates never use treehouse worktrees,
#     so the main firstmate home is the only relevant one.
#   - runs ${FM_DATA_OVERRIDE:-$FM_HOME/data}/<project>-setup.sh if it exists,
#     synchronously.
#   - non-fatal: a failing setup script is logged but does not block the
#     worktree handoff. Treehouse continues on hook failure by design, so
#     this script exits with the setup script's code to surface the failure
#     in treehouse's own logs without aborting the get.
#   - output is logged to $FM_HOME/state/treehouse-setup-<project>.log so
#     firstmate can inspect it. The log is worktree-keyed (not task-keyed)
#     because post_create fires at worktree creation time, before any task
#     is assigned to the worktree; a reused worktree's log is overwritten
#     on each reset, which is the right freshness behavior.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

PROJECT=$(basename "$(pwd)")
SETUP="$DATA/$PROJECT-setup.sh"

# No setup script for this project: quiet no-op.
[ -f "$SETUP" ] || exit 0

git_common_dir() {
  repo=$1
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  cd "$common" 2>/dev/null && pwd -P
}

PROJECT_CLONE="$PROJECTS/$PROJECT"
[ -d "$PROJECT_CLONE" ] || exit 0
WORKTREE_COMMON=$(git_common_dir "$(pwd)") || exit 0
PROJECT_COMMON=$(git_common_dir "$PROJECT_CLONE") || exit 0
[ "$WORKTREE_COMMON" = "$PROJECT_COMMON" ] || exit 0

mkdir -p "$STATE"
LOG="$STATE/treehouse-setup-$PROJECT.log"
# Capture the exit code explicitly: `if cmd; then ...; fi` without `else`
# returns 0 on a false condition (POSIX), so `$?` after `fi` is useless here.
set +e
bash "$SETUP" >"$LOG" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "fm-treehouse-post-create: setup script exited $rc for $PROJECT; see $LOG" >&2
fi
exit "$rc"
