#!/usr/bin/env bash
# Merge a task's PR/MR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR/MR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` or `bytedcli codebase mr merge` - the common
# shape of a yolo-authorized merge - can skip the recording step entirely.
# Teardown then has nothing to look up for a squash-merge-then-delete-branch
# flow and false-refuses provably landed work. This script makes recording part
# of the merge itself, so it cannot be skipped by omission. Use it for every
# PR/MR merge (captain-requested or yolo-authorized), in place of calling the
# provider merge tool directly.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Codebase bytedcli accepts https://code.byted.org/<repo-path>/merge_requests/<n>
# as a selector elsewhere, but its merge command is number + -R <repo>.
# bytedcli codebase mr merge supports --merge-method merge_commit|rebase_merge
# and --squash-commits <bool>. This helper maps the default to a squash merge
# with --merge-method merge_commit --squash-commits true, maps --merge, --squash,
# --rebase, and --method=<merge|squash|rebase|merge_commit|rebase_merge>, and
# passes explicit Codebase flags through.
#
# Extra args must not include --repo, -R, --repo-id, or --mr-id because the repo
# and MR are parsed from the PR/MR URL.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra provider merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra provider merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra provider merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"

fm_scm_parse_pr_url "$URL" >/dev/null || exit 1
fm_scm_reject_url_override_args "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

fm_scm_merge_url "$URL" "$@"
