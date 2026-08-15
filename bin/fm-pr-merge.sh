#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
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
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --match-head-commit|--match-head-commit=*)
        echo "error: extra merge arguments must not override the verified PR head" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

EXPECTED_HEAD=${FM_PR_EXPECTED_HEAD:-}
if [ -n "$EXPECTED_HEAD" ]; then
  if ! fm_pr_head_valid "$EXPECTED_HEAD"; then
    echo "error: verified PR head is invalid" >&2
    exit 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh is required to verify the current PR head" >&2
    exit 1
  fi
  if ! CURRENT_HEAD=$(gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    || ! fm_pr_head_valid "$CURRENT_HEAD"; then
    echo "error: could not resolve the current PR head" >&2
    exit 1
  fi
  if [ "$CURRENT_HEAD" != "$EXPECTED_HEAD" ]; then
    echo "error: PR head changed after verification" >&2
    exit 1
  fi
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ -n "$EXPECTED_HEAD" ] && ! grep -qxF "pr_head=$EXPECTED_HEAD" "$META"; then
  echo "error: PR head changed while refreshing merge metadata" >&2
  exit 1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi
[ -z "$EXPECTED_HEAD" ] || merge_args+=(--match-head-commit "$EXPECTED_HEAD")

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
