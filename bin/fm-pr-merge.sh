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
# Provider is auto-detected from the PR URL via bin/fm-scm-lib.sh. For an Azure
# DevOps PR URL this script REFUSES: firstmate never merges/completes an ADO PR
# (captain policy) - the ship path ends at "gates verified green -> ready" and
# the captain completes it in the ADO UI (squash to match GitHub, never
# --delete-source-branch). See docs/ado-backend.md. GitHub merge behaviour below
# is unchanged.
#
# Merge method (GitHub): defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator. An
# explicit caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
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
# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# Parse the PR URL into provider fields (github: PR_OWNER/PR_REPO/PR_NUMBER;
# ado: recognized but never mergeable here - see below). Preserves the legacy
# refusal for any unrecognized URL.
parse_pr_url() {
  local url=$1
  fm_scm_parse_pr_url "$url" || return 1
  PROVIDER=$FM_SCM_PROVIDER
  PR_NUMBER=$FM_SCM_PR_NUMBER
  PR_OWNER=$FM_SCM_PR_OWNER
  PR_REPO=$FM_SCM_PR_REPO
  return 0
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

# firstmate never merges/completes an Azure DevOps PR (captain policy): ADO
# completion is often gated behind required org policies, and the ship path ends
# at "gates verified green -> ready". Refuse and point the captain at the ADO UI.
if [ "$PROVIDER" = ado ]; then
  echo "error: firstmate does not merge Azure DevOps PRs." >&2
  echo "The gates are verified green; complete this PR yourself in the Azure DevOps UI: $URL" >&2
  echo "Use squash to match GitHub, and do NOT delete the source branch." >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
