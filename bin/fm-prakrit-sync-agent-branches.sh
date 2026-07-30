#!/usr/bin/env bash
# Sync PropPlane agent sandboxes from origin/prakrit and refresh localhost review servers.
#
# Standing captain order (2026-07-28): whenever origin/prakrit moves, each keeper
# sandbox (claude-1, claude-2, cursor-1, cursor-2) receives prakrit locally, pushes
# its branch, and restarts its dev server. After an agent promotes into prakrit, use
# --reset-from-prakrit so every sandbox matches integration exactly.
#
# Usage:
#   fm-prakrit-sync-agent-branches.sh                    # sync all sandboxes
#   fm-prakrit-sync-agent-branches.sh cursor-1           # one branch
#   fm-prakrit-sync-agent-branches.sh --reset-from-prakrit
#   fm-prakrit-sync-agent-branches.sh --dry-run
#   fm-prakrit-sync-agent-branches.sh --no-restart
#   fm-prakrit-sync-agent-branches.sh --no-push
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

DRY_RUN=0
NO_RESTART=0
NO_PUSH=0
RESET_FROM_PRAKRIT=0
FORCE=0
ONLY_BRANCH=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --no-push) NO_PUSH=1 ;;
    --reset-from-prakrit) RESET_FROM_PRAKRIT=1 ;;
    --force) FORCE=1 ;;
    --help|-h)
      echo "usage: fm-prakrit-sync-agent-branches.sh [--dry-run] [--no-restart] [--no-push] [--reset-from-prakrit] [--force] [branch]"
      echo "  --reset-from-prakrit  hard-reset each sandbox to origin/prakrit; refuses on a"
      echo "                        worktree with uncommitted work unless --force is given"
      echo "  --force               CAPTAIN-AUTHORIZED ONLY: discard uncommitted sandbox work"
      exit 0
      ;;
    *)
      if [ -n "$ONLY_BRANCH" ]; then
        echo "unknown argument: $arg" >&2
        exit 2
      fi
      ONLY_BRANCH=$arg
      ;;
  esac
done

GIT_ROOT=$(fm_proplane_agent_git_root) || {
  echo "proplane-prakrit-sync: missing GIT_ROOT in $FM_PROPLANE_AGENT_CONFIG" >&2
  exit 1
}
[ -d "$GIT_ROOT/.git" ] || {
  echo "proplane-prakrit-sync: not a git repo: $GIT_ROOT" >&2
  exit 1
}

run_git() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY git -C $*"
    return 0
  fi
  git -C "$@"
}

ensure_worktree() {
  local branch=$1 worktree=$2
  if [ -d "$worktree/.git" ] || [ -f "$worktree/.git" ]; then
    return 0
  fi
  echo "proplane-prakrit-sync: adding worktree $worktree for $branch"
  mkdir -p "$(dirname "$worktree")"
  run_git "$GIT_ROOT" fetch origin "$branch" || true
  if run_git "$GIT_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    run_git "$GIT_ROOT" worktree add -B "$branch" "$worktree" "origin/$branch"
  else
    run_git "$GIT_ROOT" worktree add -B "$branch" "$worktree" "origin/prakrit"
  fi
}

sync_prakrit_integration() {
  local line branch worktree port
  line=$(fm_proplane_agent_integration_rows) || return 0
  IFS=$'\t' read -r branch worktree port <<<"$line"
  ensure_worktree "$branch" "$worktree"
  echo "== sync integration $branch @ $worktree =="
  run_git "$worktree" fetch origin prakrit "$branch" || return 1
  run_git "$worktree" checkout "$branch"
  if run_git "$worktree" merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null; then
    run_git "$worktree" merge --ff-only "origin/$branch" || run_git "$worktree" pull --ff-only origin "$branch" || true
  else
    if [ "$DRY_RUN" -eq 0 ]; then
      fm_proplane_assert_resettable "$worktree" "proplane-prakrit-sync" "$FORCE" || return 1
    fi
    run_git "$worktree" reset --hard "origin/$branch" || return 1
  fi
  if [ "$NO_RESTART" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$worktree" "$port" || true
  fi
}

sync_sandbox() {
  local branch=$1 worktree=$2 port=$3
  ensure_worktree "$branch" "$worktree"
  echo "== merge prakrit -> $branch @ $worktree (localhost:$port) =="

  # A sandbox branch may not exist on origin yet; fetching it must not sink the
  # prakrit fetch that the merge actually depends on.
  run_git "$worktree" fetch origin prakrit || return 1
  run_git "$worktree" fetch origin "$branch" 2>/dev/null || true
  run_git "$worktree" checkout "$branch"

  if run_git "$worktree" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    if run_git "$worktree" merge-base --is-ancestor HEAD "origin/$branch"; then
      run_git "$worktree" merge --ff-only "origin/$branch" || true
    fi
  fi

  if [ "$RESET_FROM_PRAKRIT" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      fm_proplane_assert_resettable "$worktree" "proplane-prakrit-sync" "$FORCE" || return 1
    fi
    echo "proplane-prakrit-sync: reset $branch to origin/prakrit"
    run_git "$worktree" reset --hard "origin/prakrit" || return 1
  elif run_git "$worktree" merge-base --is-ancestor "origin/prakrit" HEAD 2>/dev/null; then
    echo "proplane-prakrit-sync: $branch already contains origin/prakrit"
  else
    if ! run_git "$worktree" merge --no-edit "origin/prakrit" -m "chore(sync): prakrit into $branch"; then
      echo "proplane-prakrit-sync: BLOCKED merge conflict on $branch — resolve in $worktree" >&2
      return 1
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$NO_PUSH" -eq 0 ]; then
      run_git "$worktree" push origin "$branch"
    fi
    if [ "$NO_RESTART" -eq 0 ]; then
      "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$worktree" "$port" || true
    fi
  fi
  echo "proplane-prakrit-sync: ok $branch -> http://localhost:${port}"
}

main() {
  run_git "$GIT_ROOT" fetch origin prakrit || exit 1
  sync_prakrit_integration || true

  local failed=0
  while IFS=$'\t' read -r branch worktree port; do
    [ -n "$branch" ] || continue
    if [ -n "$ONLY_BRANCH" ] && [ "$branch" != "$ONLY_BRANCH" ]; then
      continue
    fi
    if ! sync_sandbox "$branch" "$worktree" "$port"; then
      failed=$((failed + 1))
    fi
  done < <(fm_proplane_agent_sandbox_rows)

  if [ "$failed" -gt 0 ]; then
    echo "proplane-prakrit-sync: $failed branch(es) failed" >&2
    exit 1
  fi
  echo "proplane-prakrit-sync: all agent branches synced from prakrit"
}

main
