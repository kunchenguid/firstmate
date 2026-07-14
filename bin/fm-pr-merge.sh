#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` directly.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Merge queue fallback: GitHub rejects `gh-axi pr merge` on merge-queue-protected
# default branches with either "The merge strategy for <branch> is set by the
# merge queue" or "Auto merge is not allowed for this repository".
# When either signature appears, this script resolves the PR node id with
# `gh api graphql`, enqueues it with `enqueuePullRequest`, and prints the queue
# position, state, and estimatedTimeToMerge returned by GitHub.
# These two GraphQL calls deliberately use plain `gh` instead of gh-axi:
# gh-axi's `api` command is REST-path-only (no graphql subcommand, no GraphQL
# variable flags, no --jq), so it cannot express this mutation.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

merge_queue_signature() {
  local file=$1
  grep -Eq '! The merge strategy for .+ is set by the merge queue' "$file" && return 0
  grep -Fq 'GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)' "$file" && return 0
  return 1
}

enqueue_merge_queue() {
  local node_id query mutation
  # shellcheck disable=SC2016  # GraphQL variables belong to GitHub, not this shell.
  query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { id } } }'
  node_id=$(gh api graphql -f query="$query" -f owner="$PR_OWNER" -f repo="$PR_REPO" -F number="$PR_NUMBER" --jq '.data.repository.pullRequest.id // empty')
  [ -n "$node_id" ] || { echo "error: GitHub returned no node id for $URL" >&2; return 1; }

  # shellcheck disable=SC2016  # GraphQL variables belong to GitHub, not this shell.
  mutation='mutation($pullRequestId: ID!) { enqueuePullRequest(input: {pullRequestId: $pullRequestId}) { mergeQueueEntry { position state estimatedTimeToMerge } } }'
  gh api graphql -f query="$mutation" -f pullRequestId="$node_id" \
    --jq '.data.enqueuePullRequest.mergeQueueEntry | "enqueued in merge queue: position=\(.position // "unknown") state=\(.state // "unknown") estimatedTimeToMerge=\(.estimatedTimeToMerge // "unknown")"'
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

MERGE_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge.stderr.XXXXXX")
# shellcheck disable=SC2329  # Invoked by the EXIT trap.
cleanup() {
  rm -f "$MERGE_STDERR"
}
trap cleanup EXIT

set +e
gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@" 2> "$MERGE_STDERR"
merge_rc=$?
set -e

cat "$MERGE_STDERR" >&2

if [ "$merge_rc" -eq 0 ]; then
  exit 0
fi

if merge_queue_signature "$MERGE_STDERR"; then
  enqueue_merge_queue
  exit $?
fi

exit "$merge_rc"
