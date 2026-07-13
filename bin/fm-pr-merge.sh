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
GITHUB_ROUTE=${FM_GITHUB_ROUTE:-default}

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
GITHUB_ROUTE=${FM_GITHUB_ROUTE:-default}

github_quota_check() {
  "$SCRIPT_DIR/fm-shared-github-quota.sh" check --provider github --route "$GITHUB_ROUTE" 2>/dev/null || true
}

mark_github_quota_from_file() {
  local source=$1 file=$2
  "$SCRIPT_DIR/fm-shared-github-quota.sh" mark-from-text --provider github --route "$GITHUB_ROUTE" \
    --source "$source" --file "$file" >/dev/null 2>&1 || true
}

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

quota_out=$(github_quota_check)
quota_state=$(printf '%s\n' "$quota_out" | sed -n 's/^state=//p' | tail -1)
if [ "$quota_state" = defer ]; then
  echo "error: GitHub shared quota cooldown is active; refusing gh-axi pr merge before reset" >&2
  printf 'escalation=github_shared_quota\n' >&2
  printf 'provider=github\n' >&2
  printf 'account=%s\n' "$(printf '%s\n' "$quota_out" | sed -n 's/^account=//p' | tail -1)" >&2
  printf 'route=%s\n' "$(printf '%s\n' "$quota_out" | sed -n 's/^route=//p' | tail -1)" >&2
  printf 'reset_at=%s\n' "$(printf '%s\n' "$quota_out" | sed -n 's/^reset_at=//p' | tail -1)" >&2
  printf 'reset_epoch=%s\n' "$(printf '%s\n' "$quota_out" | sed -n 's/^reset_epoch=//p' | tail -1)" >&2
  printf 'operation=pr merge %s --repo %s/%s\n' "$PR_NUMBER" "$PR_OWNER" "$PR_REPO" >&2
  printf 'needed_action=wait until reset or use an alternate verified GitHub account/route with headroom\n' >&2
  exit 1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

merge_err=$(mktemp "${TMPDIR:-/tmp}/fm-gh-merge.XXXXXXXX") || exit 1
if gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>"$merge_err"; then
  [ ! -s "$merge_err" ] || cat "$merge_err" >&2
  rm -f "$merge_err"
else
  status=$?
  [ ! -s "$merge_err" ] || cat "$merge_err" >&2
  mark_github_quota_from_file "fm-pr-merge:$URL" "$merge_err"
  rm -f "$merge_err"
  exit "$status"
fi
