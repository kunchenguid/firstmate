#!/usr/bin/env bash
# Promote origin/prakrit to main with security review + no-mistakes validation.
#
# Keeper ladder: prakrit (integration) → main (Vercel Preview). Never pushes fm/*
# branches. Uses a local integrate/prakrit-to-main branch for validation only.
#
# Usage:
#   fm-proplane-promote-prakrit-to-main.sh              # validate + restart prakrit dev server (no push)
#   fm-proplane-promote-prakrit-to-main.sh --push-main  # after captain tests localhost
#   fm-proplane-promote-prakrit-to-main.sh --validate-only
#   fm-proplane-promote-prakrit-to-main.sh --dry-run
#
# After this script's no-mistakes run parks at a gate, drive gates with
# no-mistakes axi respond (firstmate or the validation worker owns responses).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

INTEGRATE_BRANCH=integrate/prakrit-to-main
DRY_RUN=0
VALIDATE_ONLY=0
PUSH_MAIN=0
SKIP_GATES=0
SKIP_SECURITY_REVIEW=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --validate-only) VALIDATE_ONLY=1 ;;
    --push-main) PUSH_MAIN=1 ;;
    --skip-gates) SKIP_GATES=1 ;;
    --skip-security-review) SKIP_SECURITY_REVIEW=1 ;;
    --force) FORCE=1 ;;
    --help|-h)
      echo "usage: fm-proplane-promote-prakrit-to-main.sh [--dry-run] [--validate-only] [--push-main] [--skip-gates] [--skip-security-review] [--force]"
      echo "  --force       CAPTAIN-AUTHORIZED ONLY: allow the staging reset and sandbox"
      echo "                realignment to discard uncommitted work in those worktrees."
      echo "  --skip-gates  CAPTAIN-AUTHORIZED ONLY: skip the security review and the"
      echo "                no-mistakes validation. Both gates are announced as SKIPPED in"
      echo "                the output so the promotion record shows they did not run."
      echo "  --skip-security-review  CAPTAIN-AUTHORIZED ONLY: skip security review only;"
      echo "                no-mistakes validation still runs."
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

GIT_ROOT=$(fm_proplane_agent_git_root) || {
  echo "proplane-promote-main: missing GIT_ROOT" >&2
  exit 1
}

command -v no-mistakes >/dev/null 2>&1 || {
  echo "proplane-promote-main: no-mistakes CLI required" >&2
  exit 1
}

run_git() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY git -C $*"
    return 0
  fi
  git -C "$@"
}

prepare_integrate_branch() {
  run_git "$GIT_ROOT" fetch origin prakrit main || return 1
  if run_git "$GIT_ROOT" show-ref --verify --quiet "refs/heads/$INTEGRATE_BRANCH"; then
    run_git "$GIT_ROOT" branch -D "$INTEGRATE_BRANCH" || true
  fi
  run_git "$GIT_ROOT" checkout -B "$INTEGRATE_BRANCH" origin/main || return 1
  if ! run_git "$GIT_ROOT" merge --no-edit origin/prakrit \
    -m "integrate(prakrit): promote integration to main (validation branch)"; then
    echo "proplane-promote-main: BLOCKED merge conflict — resolve in $GIT_ROOT on $INTEGRATE_BRANCH" >&2
    return 1
  fi
}

run_security_review() {
  "$SCRIPT_DIR/fm-proplane-security-review.sh" "$GIT_ROOT" --base main --head "$INTEGRATE_BRANCH"
}

run_no_mistakes() {
  local intent
  intent='Promote integrated prakrit changes to main for Vercel Preview after captain-approved gate. Security review completed; validate review, tests, document, and lint before fast-forward push to origin/main. No fm/* remote branches.'
  echo "== no-mistakes validation on $INTEGRATE_BRANCH =="
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY no-mistakes axi run --intent ... --skip=push,pr,ci"
    return 0
  fi
  (
    cd "$GIT_ROOT"
    git checkout "$INTEGRATE_BRANCH"
    no-mistakes axi run \
      --intent "$intent" \
      --skip=push,pr,ci
  )
}

merge_and_push_main() {
  echo "== fast-forward main from $INTEGRATE_BRANCH =="
  run_git "$GIT_ROOT" fetch origin main || return 1
  run_git "$GIT_ROOT" checkout main || return 1
  run_git "$GIT_ROOT" merge --ff-only "$INTEGRATE_BRANCH" || return 1
  run_git "$GIT_ROOT" push origin main || return 1
  run_git "$GIT_ROOT" branch -D "$INTEGRATE_BRANCH" 2>/dev/null || true
  echo "proplane-promote-main: pushed origin/main (Vercel Preview will build)"
  sync_prakrit_from_main || return 1
}

sync_prakrit_from_main() {
  local line prakrit_worktree
  line=$(fm_proplane_agent_integration_rows) || return 0
  IFS=$'\t' read -r _ prakrit_worktree _ <<<"$line"
  echo "== sync origin/main into prakrit =="
  run_git "$prakrit_worktree" fetch origin main prakrit || return 1
  run_git "$prakrit_worktree" checkout prakrit || return 1
  if ! run_git "$prakrit_worktree" merge --ff-only origin/main 2>/dev/null; then
    run_git "$prakrit_worktree" merge --no-edit origin/main \
      -m "merge(main): keep integration aligned after main promote" || return 1
  fi
  run_git "$prakrit_worktree" push origin prakrit || return 1
  local sync_args=(--reset-from-prakrit)
  [ "$FORCE" -eq 1 ] && sync_args+=(--force)
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY fm-prakrit-sync-agent-branches.sh ${sync_args[*]}"
    return 0
  fi
  "$SCRIPT_DIR/fm-prakrit-sync-agent-branches.sh" "${sync_args[@]}" || return 1
  echo "proplane-promote-main: prakrit and sandboxes aligned to main"
}

restart_prakrit_dev_server() {
  local line prakrit_worktree prakrit_port
  line=$(fm_proplane_agent_integration_rows) || return 0
  IFS=$'\t' read -r _ prakrit_worktree prakrit_port <<<"$line"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY fm-proplane-dev-server.sh restart $prakrit_worktree $prakrit_port"
    return 0
  fi
  "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$prakrit_worktree" "$prakrit_port" || true
}

stage_integrate_for_local_test() {
  local line prakrit_worktree prakrit_port integrate_sha
  line=$(fm_proplane_agent_integration_rows) || return 0
  IFS=$'\t' read -r _ prakrit_worktree prakrit_port <<<"$line"
  integrate_sha=$(git -C "$GIT_ROOT" rev-parse "$INTEGRATE_BRANCH")
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY stage $prakrit_worktree at $integrate_sha for localhost:$prakrit_port"
    return 0
  fi
  fm_proplane_assert_resettable "$prakrit_worktree" "proplane-promote-main" "$FORCE" || return 1
  run_git "$prakrit_worktree" checkout prakrit || return 1
  run_git "$prakrit_worktree" reset --hard "$integrate_sha" || return 1
  echo "proplane-promote-main: prakrit worktree staged at integrate tip for localhost test"
}

main() {
  if [ "$VALIDATE_ONLY" -eq 0 ]; then
    echo "== prepare $INTEGRATE_BRANCH =="
    prepare_integrate_branch || exit 1
    if [ "$SKIP_GATES" -eq 1 ] || [ "$SKIP_SECURITY_REVIEW" -eq 1 ]; then
      echo "== security review: SKIPPED (captain-authorized) =="
    else
      echo "== security review =="
      run_security_review || exit 1
    fi
  else
    run_git "$GIT_ROOT" checkout "$INTEGRATE_BRANCH" 2>/dev/null || {
      echo "proplane-promote-main: missing $INTEGRATE_BRANCH — run without --validate-only first" >&2
      exit 1
    }
  fi

  if [ "$SKIP_GATES" -eq 1 ]; then
    echo "== no-mistakes validation: SKIPPED by --skip-gates (captain-authorized) =="
  else
    run_no_mistakes || {
      echo "proplane-promote-main: no-mistakes did not complete — drive gates with no-mistakes axi respond, then re-run --validate-only" >&2
      exit 1
    }
  fi

  if [ "$VALIDATE_ONLY" -eq 0 ]; then
    stage_integrate_for_local_test || exit 1
    restart_prakrit_dev_server
  fi

  if [ "$PUSH_MAIN" -eq 0 ]; then
    echo "proplane-promote-main: validation complete — test on http://localhost:3000"
    echo "proplane-promote-main: no push yet. After you approve, run with --push-main (no PR unless you ask)."
    exit 0
  fi

  merge_and_push_main || exit 1
  echo "proplane-promote-main: ok — main pushed; Vercel Preview building"
}

main
