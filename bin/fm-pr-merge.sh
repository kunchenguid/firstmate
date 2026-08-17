#!/usr/bin/env bash
# Merge a task's already-registered PR only at the exact immutable revision
# bound by bin/fm-pr-check.sh. This command never refreshes that binding: a moved
# head requires a fresh readiness registration and fresh approval first.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo, -R, or --match-head-commit because repository and
# immutable head come only from the validated task record.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*|--match-head-commit|--match-head-commit=*)
        echo "error: extra merge arguments must not override the repository or bound revision" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
if ! fm_pr_metadata_identity_parse "$META" \
  || [ "$FM_PR_META_PROVIDER" != github ] \
  || [ "$FM_PR_META_URL" != "$URL" ]; then
  echo "error: task $ID has no exact readiness binding for $URL; run bin/fm-pr-check.sh and obtain approval for that revision" >&2
  exit 1
fi
fm_pr_poll_artifacts_valid "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: task $ID readiness registration is incomplete or unauthenticated; run bin/fm-pr-check.sh again" >&2
  exit 1
}
BOUND_HEAD=$FM_PR_META_READY_HEAD
[ "$FM_PR_META_HEAD" = "$BOUND_HEAD" ] || {
  echo "error: task $ID has inconsistent PR and readiness revisions; register readiness again" >&2
  exit 1
}
CURRENT_HEAD=$(fm_pr_remote_head github "$URL" github.com "$PR_OWNER/$PR_REPO" "$PR_NUMBER") || {
  echo "error: cannot verify the PR's current head; refusing merge" >&2
  exit 1
}
[ "$CURRENT_HEAD" = "$BOUND_HEAD" ] || {
  echo "REFUSED: PR head moved from approved revision $BOUND_HEAD to $CURRENT_HEAD." >&2
  echo "Run bin/fm-pr-check.sh $ID $URL, review the new revision, and obtain fresh merge approval." >&2
  exit 1
}
fm_pr_github_checks_green "$URL" || {
  echo "REFUSED: PR checks are pending, red, unavailable, or the PR is not open; refusing merge at $BOUND_HEAD." >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
  --match-head-commit "$BOUND_HEAD" "${merge_args[@]+"${merge_args[@]}"}" "$@"
