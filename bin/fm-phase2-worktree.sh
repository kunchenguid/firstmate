#!/usr/bin/env bash
# Create / bind an isolated worktree for a Phase 2 task (outside Treehouse pool optional path).
# Preferred runtime remains Treehouse via fm-spawn.sh; this helper supports explicit paths.
# Usage:
#   fm-phase2-worktree.sh create <repo-path> <task-id> <worker-slug>
#   fm-phase2-worktree.sh status <worktree-path>
#   fm-phase2-worktree.sh protect-dirty <worktree-path>   # exit 2 if dirty
#   fm-phase2-worktree.sh clean-merged <worktree-path>    # refuse if dirty
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CFG="$FM_HOME/phase2/config/concurrency.json"
ROOT=$(python3 -c "import json;print(json.load(open('$CFG')).get('worktree_root','/home/unifiedops/agentic/worktrees'))")
CMD="${1:?}"
shift

case "$CMD" in
  create)
    REPO="${1:?repo-path}"
    TID="${2:?task-id}"
    WORKER="${3:?worker-slug}"
    REPO=$(cd "$REPO" && pwd)
    NAME=$(basename "$REPO")
    BRANCH="fm/${TID}-${WORKER}"
    DEST="$ROOT/$NAME/${TID}-${WORKER}"
    mkdir -p "$(dirname "$DEST")"
    if [ -e "$DEST" ]; then
      echo "worktree exists: $DEST" >&2
      exit 1
    fi
    # never checkout main as worker branch tip without creating branch from main tip
    git -C "$REPO" fetch origin 2>/dev/null || true
    BASE=$(git -C "$REPO" rev-parse origin/main 2>/dev/null || git -C "$REPO" rev-parse main)
    git -C "$REPO" worktree add -b "$BRANCH" "$DEST" "$BASE"
    echo "worktree=$DEST branch=$BRANCH base=$BASE"
    ;;
  status)
    WT="${1:?}"
    git -C "$WT" status -sb
    git -C "$WT" rev-parse --abbrev-ref HEAD
    ;;
  protect-dirty)
    WT="${1:?}"
    if [ -n "$(git -C "$WT" status --porcelain)" ]; then
      echo "dirty worktree: $WT" >&2
      exit 2
    fi
    echo "clean"
    ;;
  clean-merged)
    WT="${1:?}"
    if [ -n "$(git -C "$WT" status --porcelain)" ]; then
      echo "refusing to remove dirty worktree: $WT" >&2
      exit 2
    fi
    BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
    git -C "$WT" worktree remove "$WT"
    echo "removed $WT (branch $BRANCH retained unless pruned manually)"
    ;;
  *)
    echo "unknown command" >&2
    exit 2
    ;;
esac
