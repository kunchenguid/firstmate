#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical PR URL is parsed by bin/fm-pr-lib.sh. GitHub keeps its
# existing gh-axi number plus owner/repository dispatch. Configured Gitea uses
# the common private forge client and confirms merged state after the request.
# GitLab merge remains unsupported and is refused.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Gitea accepts only method flags plus --delete-branch; unknown provider flags
# are refused instead of being translated ambiguously.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <provider merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-forge-lib.sh
. "$SCRIPT_DIR/fm-forge-lib.sh"

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
if [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != gitea ]; then
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

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if [ "$FM_PR_PROVIDER" = github ]; then
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
  exit $?
fi

gitea_method=
gitea_delete=false
set -- "${merge_args[@]+"${merge_args[@]}"}" "$@"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash) gitea_method=squash ;;
    --merge) gitea_method=merge ;;
    --rebase) gitea_method=rebase ;;
    --method)
      [ "$#" -ge 2 ] || { echo "error: incomplete Gitea merge method" >&2; exit 1; }
      gitea_method=$2
      shift
      ;;
    --method=*) gitea_method=${1#--method=} ;;
    --delete-branch) gitea_delete=true ;;
    *) echo "error: unsupported Gitea merge argument" >&2; exit 1 ;;
  esac
  shift
done
case "$gitea_method" in squash|merge|rebase|rebase-merge) ;; *) echo "error: unsupported Gitea merge method" >&2; exit 1 ;; esac
if ! fm_forge_pr_merge "$URL" "$gitea_method" "$gitea_delete"; then
  echo "error: ${FM_FORGE_ERROR:-Gitea merge failed}" >&2
  exit 1
fi
