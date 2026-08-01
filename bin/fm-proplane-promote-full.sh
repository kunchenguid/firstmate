#!/usr/bin/env bash
# Full PropPlane ladder promote: agent sandbox → prakrit → main → production.
#
# Standing captain workflow (also invoked via /promote skill):
#   1. Push the active (or named) keeper branch if the worktree has unpushed commits
#   2. fm-proplane-promote-to-prakrit.sh
#   3. fm-proplane-promote-prakrit-to-main.sh --push-main (security review +
#      no-mistakes, then the prakrit → main promotion record PR)
#   4. scripts/promote-main-to-production.sh in the PropPlane git root
#
# Usage:
#   fm-proplane-promote-full.sh [agent-branch] [--dry-run] [--no-production] [--skip-agent-push]
#   fm-proplane-promote-full.sh cursor-2
#   fm-proplane-promote-full.sh --no-production
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"
# shellcheck source=bin/fm-proplane-promote-pr-lib.sh
. "$SCRIPT_DIR/fm-proplane-promote-pr-lib.sh"

DRY_RUN=0
SKIP_PRODUCTION=0
SKIP_AGENT_PUSH=0
SKIP_SECURITY_REVIEW=0
FORCE=0
AGENT_BRANCH=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-production) SKIP_PRODUCTION=1 ;;
    --skip-agent-push) SKIP_AGENT_PUSH=1 ;;
    --skip-security-review) SKIP_SECURITY_REVIEW=1 ;;
    --force) FORCE=1 ;;
    --help|-h)
      echo "usage: fm-proplane-promote-full.sh [agent-branch] [--dry-run] [--no-production] [--skip-agent-push] [--skip-security-review] [--force]"
      echo "  --force  CAPTAIN-AUTHORIZED ONLY: let the ladder's sandbox realignment"
      echo "           discard uncommitted work. Without it, promotion stops rather than"
      echo "           hard-resetting a worktree that still holds unlanded changes."
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

if [ -z "$AGENT_BRANCH" ]; then
  AGENT_BRANCH=$("$SCRIPT_DIR/fm-proplane-active-worktree.sh" --branch)
fi

if ! fm_proplane_agent_is_sandbox "$AGENT_BRANCH"; then
  echo "proplane-promote-full: $AGENT_BRANCH is not a sandbox keeper branch" >&2
  exit 2
fi

GIT_ROOT=$(fm_proplane_agent_git_root) || {
  echo "proplane-promote-full: missing GIT_ROOT in config/proplane-agent-branches" >&2
  exit 1
}

agent_worktree=""
while IFS=$'\t' read -r b wt _; do
  [ "$b" = "$AGENT_BRANCH" ] || continue
  agent_worktree=$wt
  break
done < <(fm_proplane_agent_rows)

[ -n "$agent_worktree" ] || {
  echo "proplane-promote-full: no worktree for branch $AGENT_BRANCH" >&2
  exit 1
}

run_git() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY git -C $*"
    return 0
  fi
  git -C "$@"
}

push_agent_branch() {
  if [ "$SKIP_AGENT_PUSH" -eq 1 ]; then
    echo "proplane-promote-full: skipping agent push (--skip-agent-push)"
    return 0
  fi
  echo "== push origin/$AGENT_BRANCH from $agent_worktree =="
  run_git "$agent_worktree" fetch origin "$AGENT_BRANCH" || return 1
  local local_sha remote_sha
  local_sha=$(git -C "$agent_worktree" rev-parse HEAD)
  remote_sha=$(git -C "$agent_worktree" rev-parse "origin/$AGENT_BRANCH" 2>/dev/null || echo "")
  if [ "$local_sha" = "$remote_sha" ]; then
    echo "proplane-promote-full: origin/$AGENT_BRANCH already at $(git -C "$agent_worktree" rev-parse --short HEAD)"
    return 0
  fi
  if ! run_git "$agent_worktree" push origin "HEAD:$AGENT_BRANCH"; then
    echo "proplane-promote-full: failed to push $AGENT_BRANCH — commit and push manually, then re-run" >&2
    return 1
  fi
}

# Preview the promotion record PR the prakrit → main step will open. The range
# shown is the pre-promotion origin/main..origin/prakrit, since a dry run never
# merges the agent branch into prakrit; the real PR records the merged range.
preview_promotion_pr() {
  local base_ref=origin/main head_ref=origin/prakrit
  local base_sha head_sha title body_file pending
  pending='pending (runs during the prakrit → main step)'
  base_sha=$(fm_proplane_promote_pr_short_sha "$GIT_ROOT" "$base_ref")
  head_sha=$(fm_proplane_promote_pr_short_sha "$GIT_ROOT" "$head_ref")
  title=$(fm_proplane_promote_pr_title "$base_sha" "$head_sha")
  body_file=$(mktemp)
  fm_proplane_promote_pr_body "$GIT_ROOT" "$base_ref" "$head_ref" \
    "$pending" "" "$pending" >"$body_file"
  fm_proplane_promote_pr_sync "$GIT_ROOT" main prakrit "$title" "$body_file" 1 || true
  rm -f "$body_file"
}

main() {
  push_agent_branch || exit 1

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY $SCRIPT_DIR/fm-proplane-promote-to-prakrit.sh $AGENT_BRANCH"
    echo "DRY $SCRIPT_DIR/fm-proplane-promote-prakrit-to-main.sh --push-main"
    preview_promotion_pr
    if [ "$SKIP_PRODUCTION" -eq 0 ]; then
      echo "DRY bash $GIT_ROOT/scripts/promote-main-to-production.sh"
    fi
    exit 0
  fi

  to_prakrit_args=("$AGENT_BRANCH")
  [ "$FORCE" -eq 1 ] && to_prakrit_args+=(--force)
  "$SCRIPT_DIR/fm-proplane-promote-to-prakrit.sh" "${to_prakrit_args[@]}" || exit 1
  promote_main_args=(--push-main)
  if [ "$SKIP_SECURITY_REVIEW" -eq 1 ]; then
    promote_main_args+=(--skip-security-review)
  fi
  [ "$FORCE" -eq 1 ] && promote_main_args+=(--force)
  "$SCRIPT_DIR/fm-proplane-promote-prakrit-to-main.sh" "${promote_main_args[@]}" || exit 1

  if [ "$SKIP_PRODUCTION" -eq 0 ]; then
    echo "== promote main → production =="
    (cd "$GIT_ROOT" && bash scripts/promote-main-to-production.sh) || exit 1
  else
    echo "proplane-promote-full: skipped production (--no-production)"
  fi

  echo "proplane-promote-full: ok — prakrit, main, and production aligned (live: prop-lane.space; iOS TestFlight workflow should run on production push)"
}

main
