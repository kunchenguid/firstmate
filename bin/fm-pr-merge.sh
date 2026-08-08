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
# A Gitea PR URL (fm-pr-url-lib.sh: any host, plural "pulls") is merged with
# `tea pulls merge` instead, run with cwd inside the task's worktree so tea
# auto-discovers the right login/host from its origin remote.
#
# A Bitbucket PR URL (fm-pr-url-lib.sh: any host, plural "pull-requests") has no
# CLI equivalent here, so it cannot be auto-merged: after recording pr= the
# script prints open-URL guidance and exits non-zero, telling firstmate the merge
# must happen manually in the browser (teardown's content-in-default fallback
# then verifies the merge landed). It never invokes gh-axi or tea for a Bitbucket
# PR, and needs no worktree because there is no CLI login context to resolve.
#
# Merge method: defaults to --squash (gh-axi) / --style squash (tea) when the
# caller passes no explicit method after the optional -- separator. An explicit
# caller method is never overridden. For a Gitea PR the caller passes tea's own
# `--style <merge|rebase|squash|rebase-merge>` flag; gh-axi's --squash/--merge/
# --rebase/--method flags are gh-specific and are not translated.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi/tea merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi/tea merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi/tea merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-url-lib.sh
. "$SCRIPT_DIR/fm-pr-url-lib.sh"
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

caller_has_style_arg() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --style|--style=*) return 0 ;;
    esac
  done
  return 1
}

parse_pr_url() {
  local url=$1
  if fm_parse_pr_url "$url"; then
    PR_FORGE=$FM_PR_FORGE
    PR_OWNER=$FM_PR_OWNER
    PR_REPO=$FM_PR_REPO
    PR_NUMBER=$FM_PR_NUMBER
    return 0
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>, a Gitea https://<host>/<owner>/<repo>/pulls/<number> URL, or a Bitbucket https://<host>/<workspace>/<repo>/pull-requests/<number> URL (got: $url)" >&2
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

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

merge_args=()
if [ "$PR_FORGE" = gitea ]; then
  if ! caller_has_style_arg "$@"; then
    merge_args=(--style squash)
  fi
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$WT" ] && [ -d "$WT" ] || { echo "error: no worktree recorded for task $ID; cannot resolve Gitea login context for tea" >&2; exit 1; }
  ( cd "$WT" && tea pulls merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@" )
elif [ "$PR_FORGE" = bitbucket ]; then
  echo "error: Bitbucket PRs are merged manually in the browser; firstmate has no CLI merge path. Open $URL and merge there, then tell firstmate it is done." >&2
  exit 1
else
  if ! caller_has_merge_method "$@"; then
    merge_args=(--squash)
  fi
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
fi
