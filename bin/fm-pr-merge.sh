#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# After a successful merge, an optional issue=<number> recorded in task metadata
# is verified through GitHub. An open issue is closed with a comment linking the
# merged PR. Issue verification or closure failures warn while returning success,
# because the already-completed merge must never look retryable.
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

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# Refresh the cached PR observation so the task's final normalized state reads
# `merged` in the fleet snapshot and in the outcome manifest teardown publishes.
# Best effort by design: the merge already succeeded and must never look
# retryable, so a failed refresh only leaves the previous observation in place.
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-pr-status.sh" refresh "$ID" >/dev/null 2>&1 || \
  echo "warning: PR merge succeeded: $URL; the cached PR state could not be refreshed" >&2

issue_close_warning() {  # <detail>
  echo "warning: PR merge succeeded: $URL; GitHub issue bookkeeping did not complete: $1" >&2
}

github_issue_state() {  # <issue-number>
  local issue=$1 output state
  output=$(gh-axi issue view "$issue" --repo "$PR_OWNER/$PR_REPO" --full) || return 1
  state=$(printf '%s\n' "$output" | awk '$1 == "state:" { print $2; exit }')
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}

ISSUE_LINE_COUNT=$(grep -c '^issue=' "$META" 2>/dev/null || true)
case "$ISSUE_LINE_COUNT" in
  0) exit 0 ;;
  1) ISSUE=$(grep '^issue=' "$META" | cut -d= -f2-) ;;
  *) issue_close_warning "task metadata has multiple recorded issues"; exit 0 ;;
esac
case "$ISSUE" in
  ''|*[!0-9]*) issue_close_warning "recorded issue identity is malformed"; exit 0 ;;
esac
if [ "$ISSUE" -le 0 ]; then
  issue_close_warning "recorded issue identity is malformed"
  exit 0
fi

if ! ISSUE_STATE=$(github_issue_state "$ISSUE"); then
  issue_close_warning "could not verify issue #$ISSUE"
  exit 0
fi
[ "$ISSUE_STATE" = closed ] && exit 0

if ! gh-axi issue close "$ISSUE" --repo "$PR_OWNER/$PR_REPO" --reason completed \
  --comment "Closed after merge of $URL."; then
  issue_close_warning "could not close issue #$ISSUE"
  exit 0
fi
if ! ISSUE_STATE=$(github_issue_state "$ISSUE") || [ "$ISSUE_STATE" != closed ]; then
  issue_close_warning "issue #$ISSUE is still not closed after the close request"
fi
exit 0
