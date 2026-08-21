#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Before merging, the forge's own check verdict is read through
# bin/fm-pr-checks-lib.sh and a failing or unreadable verdict REFUSES the merge.
# That guard exists because "never merge a red PR" previously lived only in
# AGENTS.md: on 2026-08-10 pull request 182 of nguzen/aln was merged five minutes
# after its merge-queue run failed, and the resulting commit blocked production
# deploys for two days. Pass --allow-failing-checks to merge anyway when the
# failure is known to be infrastructural rather than in the change.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-failing-checks]
#          [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-checks-lib.sh
. "$SCRIPT_DIR/fm-pr-checks-lib.sh"

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

# Own flags are consumed before the optional -- separator, so they are never
# forwarded to gh-axi. An unknown flag here is a usage error rather than a
# silently ignored intent.
ALLOW_FAILING_CHECKS=0
while [ "$#" -gt 0 ] && [ "${1:-}" != "--" ]; do
  case $1 in
    --allow-failing-checks) ALLOW_FAILING_CHECKS=1; shift ;;
    *)
      echo "error: unknown merge flag $1 (own flags: --allow-failing-checks; pass gh-axi flags after --)" >&2
      exit 2
      ;;
  esac
done
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
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# The check gate runs before any state is recorded or any poll is armed, so a
# refused merge leaves nothing behind, exactly like the earlier refusals above.
if [ "$ALLOW_FAILING_CHECKS" -eq 1 ]; then
  echo "warning: merging $URL without reading the forge's check verdict (--allow-failing-checks)" >&2
else
  fm_pr_checks_read "$PR_OWNER" "$PR_REPO" "$PR_NUMBER"
  case $FM_PR_CHECKS_STATE in
    failing)
      echo "error: refusing to merge $URL: the forge reports failing checks" >&2
      printf '%s' "$FM_PR_CHECKS_FAILING" | sed 's/^/  /' >&2
      [ -z "$FM_PR_CHECKS_QUEUE_REF" ] \
        || echo "  (merge-queue attempt read: $FM_PR_CHECKS_QUEUE_REF)" >&2
      echo "hint: land a green head, or pass --allow-failing-checks when the failure is infrastructural" >&2
      exit 1
      ;;
    unreadable)
      echo "error: refusing to merge $URL: the forge's check state is unreadable ($FM_PR_CHECKS_REASON)" >&2
      echo "hint: an unreadable verdict is never a pass; fix the read, or pass --allow-failing-checks deliberately" >&2
      exit 1
      ;;
    pending)
      echo "note: merging $URL with checks still running:" >&2
      printf '%s' "$FM_PR_CHECKS_PENDING" | sed 's/^/  /' >&2
      ;;
  esac
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
