#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The canonical GitHub or Forgejo PR URL is parsed by bin/fm-pr-lib.sh and its
# validated identity is passed to the provider CLI as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not override repository, base URL, or expected head because those values
# come only from the validated URL and recorded metadata.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra provider merge args>]
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
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || { [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != forgejo ]; }; then
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

reject_identity_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*|--base-url|--base-url=*|--expected-head|--expected-head=*)
        echo "error: extra merge arguments must not override PR identity" >&2
        return 1
        ;;
    esac
  done
}

reject_identity_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$PROVIDER" = forgejo ] && ! fm_pr_forgejo_project_authorized "$PROJECT" "$PR_HOST"; then
  echo "error: Forgejo host is not authorized by the task project remotes" >&2
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

if [ "$PROVIDER" = github ]; then
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
  exit
fi

PR_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fm_pr_head_valid "$PR_HEAD" || {
  echo "error: Forgejo pull request head is unavailable" >&2
  exit 1
}
MERGEABILITY=$(forgejo-axi pr mergeability --base-url "https://$PR_HOST" --repo "$PR_PATH" "$PR_NUMBER") || exit 1
READY=$(printf '%s\n' "$MERGEABILITY" | sed -n 's/^[[:space:]]*mergeable:[[:space:]]*//p' | head -1)
READY_HEAD=$(printf '%s\n' "$MERGEABILITY" | sed -n 's/^[[:space:]]*head_sha:[[:space:]]*//p' | head -1)
[ "$READY" = true ] && [ "$READY_HEAD" = "$PR_HEAD" ] || {
  echo "error: Forgejo pull request is not mergeable" >&2
  exit 1
}

forgejo_args=()
for arg in "${merge_args[@]+"${merge_args[@]}"}" "$@"; do
  case "$arg" in
    --squash) forgejo_args+=(--method squash) ;;
    --merge) forgejo_args+=(--method merge) ;;
    --rebase) forgejo_args+=(--method rebase) ;;
    *) forgejo_args+=("$arg") ;;
  esac
done
forgejo-axi pr merge --base-url "https://$PR_HOST" --repo "$PR_PATH" "$PR_NUMBER" \
  --expected-head "$PR_HEAD" "${forgejo_args[@]+"${forgejo_args[@]}"}"
