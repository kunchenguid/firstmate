#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical PR/MR URL is parsed by bin/fm-pr-lib.sh.
# GitHub is addressed by the derived owner/repository and PR number.
# GitLab is addressed by the derived full project URL and MR number; a lookup
# must report the exact canonical MR URL before glab is allowed to merge it.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator for GitHub,
# or neither --squash/-s nor --rebase/-r for GitLab. GitHub extra arguments
# retain their existing forwarding behavior. GitLab extra arguments are
# limited to the merge flags documented by `glab mr merge --help`. Neither
# forge accepts caller-supplied --repo/-R selectors because the target comes
# only from the validated URL.
# Usage: fm-pr-merge.sh <task-id> <pr-or-mr-url> [-- <safe forge merge args>]
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
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
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

caller_has_gitlab_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|-s|--rebase|-r) return 0 ;;
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

validate_gitlab_args() {
  local expect_value=0 arg
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
      expect_value=0
      continue
    fi
    case "$arg" in
      --squash|-s|--rebase|-r|--remove-source-branch|-d|--yes|-y|--auto-merge|--auto-merge=*) ;;
      --message|-m|--sha|--squash-message) expect_value=1 ;;
      --message=*|--sha=*|--squash-message=*) ;;
      *)
        echo "error: unsupported GitLab merge argument: $arg" >&2
        return 1
        ;;
    esac
  done
  if [ "$expect_value" -eq 1 ]; then
    echo "error: GitLab merge argument requires a value" >&2
    return 1
  fi
}

reject_repo_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || validate_gitlab_args "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

fm_pr_metadata_identity_parse "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$PR_HOST" ] && [ "$FM_PR_META_PATH" = "$PR_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$PR_NUMBER" ] || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
case "$PROVIDER" in
  github)
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
  gitlab)
    PROJECT_URL="https://$PR_HOST/$PR_PATH"
    LOOKUP=$(glab mr view "$PR_NUMBER" -R "$PROJECT_URL" 2>/dev/null) || {
      echo "error: GitLab merge request lookup failed" >&2
      exit 1
    }
    LOOKUP_URL=$(printf '%s\n' "$LOOKUP" | sed -n '/^--$/q; s/^url:[[:space:]]*//p')
    [ "$LOOKUP_URL" = "$URL" ] || {
      echo "error: GitLab merge request target could not be verified" >&2
      exit 1
    }
    if ! caller_has_gitlab_merge_method "$@"; then
      merge_args=(--squash)
    fi
    glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" "${merge_args[@]+"${merge_args[@]}"}" --yes "$@"
    ;;
esac
