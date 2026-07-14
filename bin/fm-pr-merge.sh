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
# parses the URL (via bin/fm-pr-lib.sh) and invokes gh-axi in the form it accepts.
#
# Hooks: the pr-ready hook point belongs to the recording step, so on a task
# whose PR this run is the first to record (that same no-CI-repo flow), it fires
# here rather than inside fm-pr-check.sh - after the merge, so it can never delay
# it - and still at least once, normally exactly once, per (task, PR URL). Because
# the recording is done by then, it fires even if the merge itself failed;
# post-merge, which means firstmate merged, fires only after a successful merge.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-hooks-lib.sh
. "$SCRIPT_DIR/fm-hooks-lib.sh"

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

# --defer-pr-ready-hook keeps fm-pr-check's pr-ready hook off the merge's
# critical path: a slow hook there would sit between the recording and the merge
# below. It is fired here instead, after the merge, still exactly once per
# (task, PR URL) - fm_hook_pr_ready_once gates on the fire it records in the
# meta, so a merge that fails below still fires it and a retry does not re-fire.
"$SCRIPT_DIR/fm-pr-check.sh" --defer-pr-ready-hook "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

merge_status=0
gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@" ||
  merge_status=$?

# Hook points (bin/fm-hooks-lib.sh; docs/extension-points.md), fired last so
# neither can delay the merge. Best-effort: a failing hook never fails the merge.
# pr-ready belongs to the recording step this script already performed above, so
# it fires whether or not the merge itself succeeded; post-merge means firstmate
# merged, so it fires only on a successful merge.
fm_hook_pr_ready_once "$CONFIG" "$META" "$ID" "$URL"

[ "$merge_status" -eq 0 ] || exit "$merge_status"

fm_hook_run "$CONFIG" post-merge \
  "FM_HOOK_TASK_ID=$ID" "FM_HOOK_REF=$URL" \
  -- "$ID" "$URL"
