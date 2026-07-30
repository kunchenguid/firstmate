#!/usr/bin/env bash
# Merge one agent sandbox branch into prakrit, push, prune stray remotes, realign sandboxes.
#
# Standing captain order (2026-07-28): agents land only on their keeper branch.
# After promotion, GitHub must hold only keeper branches; sandboxes reset from prakrit.
#
# Usage:
#   fm-proplane-promote-to-prakrit.sh <agent-branch> [--dry-run]
#   fm-proplane-promote-to-prakrit.sh cursor-2
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

DRY_RUN=0
FORCE=0
AGENT_BRANCH=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --help|-h)
      echo "usage: fm-proplane-promote-to-prakrit.sh <agent-branch> [--dry-run] [--force]"
      echo "  --force  CAPTAIN-AUTHORIZED ONLY: let the post-promote sandbox realignment"
      echo "           discard uncommitted work in the sandbox worktrees."
      exit 0
      ;;
    *)
      if [ -z "$AGENT_BRANCH" ]; then
        AGENT_BRANCH=$arg
      else
        echo "unknown argument: $arg" >&2
        exit 2
      fi
      ;;
  esac
done

[ -n "$AGENT_BRANCH" ] || {
  echo "agent branch required" >&2
  exit 2
}

if ! fm_proplane_agent_is_sandbox "$AGENT_BRANCH"; then
  echo "proplane-promote: $AGENT_BRANCH is not a sandbox keeper branch" >&2
  exit 2
fi

GIT_ROOT=$(fm_proplane_agent_git_root) || exit 1
line=$(fm_proplane_agent_integration_rows) || {
  echo "proplane-promote: missing prakrit row in config" >&2
  exit 1
}
IFS=$'\t' read -r prakrit_branch prakrit_worktree prakrit_port <<<"$line"

run_git() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY git -C $*"
    return 0
  fi
  git -C "$@"
}

echo "== promote $AGENT_BRANCH -> $prakrit_branch @ $prakrit_worktree =="
run_git "$GIT_ROOT" fetch origin "$AGENT_BRANCH" "$prakrit_branch" || exit 1
run_git "$prakrit_worktree" fetch origin "$AGENT_BRANCH" "$prakrit_branch" || exit 1
run_git "$prakrit_worktree" checkout "$prakrit_branch" || exit 1

if run_git "$prakrit_worktree" merge-base --is-ancestor "origin/$AGENT_BRANCH" HEAD 2>/dev/null; then
  echo "proplane-promote: prakrit already contains origin/$AGENT_BRANCH"
else
  if ! run_git "$prakrit_worktree" merge --no-edit "origin/$AGENT_BRANCH" \
    -m "merge($AGENT_BRANCH): integrate agent branch into prakrit"; then
    echo "proplane-promote: BLOCKED merge conflict — resolve in $prakrit_worktree" >&2
    exit 1
  fi
fi

run_git "$prakrit_worktree" push origin "$prakrit_branch" || exit 1

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY fm-proplane-prune-stray-branches.sh"
  echo "DRY fm-prakrit-sync-agent-branches.sh --reset-from-prakrit"
  exit 0
fi

"$SCRIPT_DIR/fm-proplane-prune-stray-branches.sh" || exit 1
sync_args=(--reset-from-prakrit)
[ "$FORCE" -eq 1 ] && sync_args+=(--force)
"$SCRIPT_DIR/fm-prakrit-sync-agent-branches.sh" "${sync_args[@]}" || exit 1
"$SCRIPT_DIR/fm-proplane-branch-e2e.sh" --smoke || {
  echo "proplane-promote: ladder smoke e2e failed after promote" >&2
  exit 1
}

echo "proplane-promote: ok $AGENT_BRANCH -> $prakrit_branch (http://localhost:${prakrit_port})"
echo "proplane-promote: test on localhost — no GitHub PR unless captain asks."
