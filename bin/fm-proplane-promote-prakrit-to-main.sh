#!/usr/bin/env bash
# Promote origin/prakrit to main with security review + no-mistakes validation.
#
# Keeper ladder: prakrit (integration) → main (Vercel Preview). Never pushes fm/*
# branches. Uses a local integrate/prakrit-to-main branch for validation only.
#
# With --push-main this also opens a prakrit → main promotion-record PR before
# the fast-forward, per the captain's standing order. See
# bin/fm-proplane-promote-pr-lib.sh for that contract; the short version is that
# the PR records what moved and never gates the promotion.
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
# shellcheck source=bin/fm-proplane-promote-pr-lib.sh
. "$SCRIPT_DIR/fm-proplane-promote-pr-lib.sh"

INTEGRATE_BRANCH=integrate/prakrit-to-main
DRY_RUN=0
VALIDATE_ONLY=0
PUSH_MAIN=0
SKIP_GATES=0
SKIP_SECURITY_REVIEW=0
FORCE=0

# Gate outcomes, recorded as they happen so the promotion PR states the evidence
# this promotion actually ran on rather than what the flags implied.
SECURITY_REVIEW_STATUS='not run in this invocation'
SECURITY_REVIEW_REPORT=''
VALIDATION_STATUS='not run in this invocation'

# The promotion record once it is opened, so a fast-forward that then fails can
# annotate the record it already published. Whether a record was opened is
# tracked apart from its number: a record whose number could not be read still
# needs saying so, while no record at all is correctly silent.
PROMOTION_PR_OPENED=0
PROMOTION_PR_NUMBER=''
PROMOTION_PR_URL=''

# Set the moment origin/main accepts the push, so a failure in the post-push
# work can never be mistaken for a promotion that did not land.
MAIN_LANDED=0

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
      echo "  --push-main   Also opens the prakrit → main promotion record PR just before"
      echo "                the fast-forward. The PR records the promoted range and the"
      echo "                gate outcomes; it never gates the promotion, and a GitHub"
      echo "                failure is warned about rather than stopping the push."
      echo "  --dry-run     Prints the promotion record PR it would open, and opens none."
      echo "                It runs no security review and no no-mistakes validation"
      echo "                either; both are recorded as NOT RUN so a preview can never"
      echo "                be read as evidence that the gates passed."
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
  local log rc
  # A dry run spends nothing: the review burns real model quota and writes a
  # report under $FM_HOME/state, which is a side effect a flag named --dry-run
  # must never produce. The real path below is untouched.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY $SCRIPT_DIR/fm-proplane-security-review.sh $GIT_ROOT --base main --head $INTEGRATE_BRANCH"
    SECURITY_REVIEW_REPORT=''
    return 0
  fi
  log=$(mktemp)
  # Tee stdout only: the review's own BLOCKED messages stay on stderr, and the
  # report path it prints becomes evidence in the promotion PR.
  "$SCRIPT_DIR/fm-proplane-security-review.sh" "$GIT_ROOT" --base main --head "$INTEGRATE_BRANCH" | tee "$log"
  rc=${PIPESTATUS[0]}
  SECURITY_REVIEW_REPORT=$(awk '
    /^proplane-security-review: report / {
      sub(/^proplane-security-review: report /, "")
      print
      exit
    }' "$log")
  # The record is published to GitHub, so only the sha-keyed filename is kept:
  # the printed path is under $FM_HOME and would carry this machine's layout.
  SECURITY_REVIEW_REPORT=$(fm_proplane_promote_pr_report_label "$SECURITY_REVIEW_REPORT")
  rm -f "$log"
  return "$rc"
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

# The recorded range describes the refs this promotion was actually built on:
# $INTEGRATE_BRANCH against the origin/main prepare_integrate_branch fetched it
# from. Re-fetching prakrit here would record whatever another agent had pushed
# in the meantime, which is not what the fast-forward below delivers.
promotion_range_refs() {
  local base_ref=origin/main head_ref=$INTEGRATE_BRANCH
  if ! git -C "$GIT_ROOT" rev-parse --verify --quiet "$head_ref" >/dev/null 2>&1; then
    # A dry run never builds the integrate branch, so preview the range the real
    # promotion would carry instead of reporting an empty one.
    head_ref=origin/prakrit
  elif ! git -C "$GIT_ROOT" merge-base --is-ancestor origin/main "$head_ref" 2>/dev/null; then
    # origin/main moved past the base this promotion was built on, so name that
    # base explicitly rather than a ref that no longer describes the range.
    base_ref=$(git -C "$GIT_ROOT" merge-base origin/main "$head_ref" 2>/dev/null) || base_ref=origin/main
  fi
  printf '%s\t%s\n' "$base_ref" "$head_ref"
}

open_promotion_pr() {
  local base_ref head_ref
  local count base_sha head_sha title body_file rc
  IFS=$'\t' read -r base_ref head_ref < <(promotion_range_refs)
  count=$(fm_proplane_promote_pr_range_count "$GIT_ROOT" "$base_ref" "$head_ref")
  if [ "$count" -eq 0 ]; then
    echo "proplane-promote-main: no commits between $base_ref and $head_ref, no promotion record needed"
    return 0
  fi
  base_sha=$(fm_proplane_promote_pr_short_sha "$GIT_ROOT" "$base_ref")
  head_sha=$(fm_proplane_promote_pr_short_sha "$GIT_ROOT" "$head_ref")
  title=$(fm_proplane_promote_pr_title "$base_sha" "$head_sha")
  body_file=$(mktemp)
  # The PR is opened from prakrit because integrate/* is never pushed to GitHub,
  # so the body is told both refs and reconciles them: the promoted range stays
  # authoritative, and any commit the rendered diff misses or adds is named.
  fm_proplane_promote_pr_body "$GIT_ROOT" "$base_ref" "$head_ref" \
    "$SECURITY_REVIEW_STATUS" "$SECURITY_REVIEW_REPORT" "$VALIDATION_STATUS" origin/prakrit >"$body_file"
  echo "== promotion record PR (prakrit → main) =="
  fm_proplane_promote_pr_sync "$GIT_ROOT" main prakrit "$title" "$body_file" "$DRY_RUN"
  rc=$?
  PROMOTION_PR_OPENED=$FM_PROPLANE_PROMOTE_PR_OPENED
  PROMOTION_PR_NUMBER=$FM_PROPLANE_PROMOTE_PR_NUMBER
  PROMOTION_PR_URL=$FM_PROPLANE_PROMOTE_PR_URL
  rm -f "$body_file"
  return "$rc"
}

# The record announces that the ladder fast-forwards main right after opening it.
# When that fast-forward does not complete, the record must say so rather than
# stand as an unqualified claim that this range went live.
#
# It fires only when main did NOT land. Everything after the push is realignment
# work: it can fail on its own, and annotating then would tell a later reader
# that a promotion which did go live never happened, which is the exact
# falsehood this annotation exists to prevent.
#
# Best-effort by design: a failed annotation is warned about and never changes
# the exit code of the push that actually failed.
annotate_failed_fast_forward() {
  local message
  if [ "$MAIN_LANDED" -eq 1 ] || [ "$PROMOTION_PR_OPENED" -ne 1 ]; then
    return 0
  fi
  if [ -z "$PROMOTION_PR_NUMBER" ]; then
    echo "proplane-promote-main: WARNING a promotion record PR was opened but its number could not be read, so it was not annotated; it still claims a promotion that did not land - annotate the open prakrit -> main PR by hand (${PROMOTION_PR_URL:-no URL reported})" >&2
    return 0
  fi
  message="proplane-promote-main: the fast-forward of \`main\` did NOT complete after this record was opened, so this record does not reflect a landed promotion. Re-run the promote once the cause is resolved."
  fm_proplane_promote_pr_comment "$GIT_ROOT" "$PROMOTION_PR_NUMBER" "$message" "$DRY_RUN" || {
    echo "proplane-promote-main: WARNING could not annotate promotion record PR #$PROMOTION_PR_NUMBER; it still claims a promotion that did not land" >&2
  }
  return 0
}

merge_and_push_main() {
  echo "== fast-forward main from $INTEGRATE_BRANCH =="
  run_git "$GIT_ROOT" fetch origin main || return 1
  run_git "$GIT_ROOT" checkout main || return 1
  run_git "$GIT_ROOT" merge --ff-only "$INTEGRATE_BRANCH" || return 1
  run_git "$GIT_ROOT" push origin main || return 1
  MAIN_LANDED=1
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
  # A dry run never builds the integrate branch, so it must not read its tip:
  # resolving a ref that does not exist would abort the very run whose job is to
  # print what a real promotion would do.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY stage $prakrit_worktree at $INTEGRATE_BRANCH for localhost:$prakrit_port"
    return 0
  fi
  integrate_sha=$(git -C "$GIT_ROOT" rev-parse "$INTEGRATE_BRANCH") || return 1
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
      SECURITY_REVIEW_STATUS='SKIPPED (captain-authorized)'
    else
      echo "== security review =="
      run_security_review || exit 1
      if [ "$DRY_RUN" -eq 1 ]; then
        SECURITY_REVIEW_STATUS='NOT RUN (--dry-run: no security review was executed in this invocation)'
      else
        SECURITY_REVIEW_STATUS='passed (no Critical or High findings)'
      fi
    fi
  else
    run_git "$GIT_ROOT" checkout "$INTEGRATE_BRANCH" 2>/dev/null || {
      echo "proplane-promote-main: missing $INTEGRATE_BRANCH — run without --validate-only first" >&2
      exit 1
    }
    SECURITY_REVIEW_STATUS='not re-run here (--validate-only resumes an earlier promotion run)'
  fi

  if [ "$SKIP_GATES" -eq 1 ]; then
    echo "== no-mistakes validation: SKIPPED by --skip-gates (captain-authorized) =="
    VALIDATION_STATUS='SKIPPED by --skip-gates (captain-authorized)'
  else
    run_no_mistakes || {
      echo "proplane-promote-main: no-mistakes did not complete — drive gates with no-mistakes axi respond, then re-run --validate-only" >&2
      exit 1
    }
    if [ "$DRY_RUN" -eq 1 ]; then
      VALIDATION_STATUS='NOT RUN (--dry-run: no validation was executed in this invocation)'
    else
      VALIDATION_STATUS='passed (no-mistakes: review, tests, document, lint)'
    fi
  fi

  if [ "$VALIDATE_ONLY" -eq 0 ]; then
    stage_integrate_for_local_test || exit 1
    restart_prakrit_dev_server
  fi

  if [ "$PUSH_MAIN" -eq 0 ]; then
    # Printing what a promotion would do is the whole job of --dry-run, and the
    # record PR is part of that, so the preview runs without --push-main too. It
    # still opens nothing: fm_proplane_promote_pr_sync makes no GitHub call here.
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "DRY --push-main would open this promotion record PR before the fast-forward"
      open_promotion_pr || {
        echo "proplane-promote-main: WARNING could not preview the promotion record PR" >&2
      }
    fi
    echo "proplane-promote-main: validation complete — test on http://localhost:3000"
    echo "proplane-promote-main: no push yet. After you approve, run with --push-main (which also opens the promotion record PR)."
    exit 0
  fi

  # The record is opened BEFORE the fast-forward, because the fast-forward is
  # what closes it as merged. A GitHub failure here is warned about and stepped
  # over: losing the record is bad, leaving main and production diverged because
  # an API call failed is worse.
  open_promotion_pr || {
    echo "proplane-promote-main: WARNING no promotion record PR was opened; the promotion continues so main and production do not diverge" >&2
  }

  if ! merge_and_push_main; then
    annotate_failed_fast_forward
    exit 1
  fi
  echo "proplane-promote-main: ok — main pushed; Vercel Preview building"
}

main
