#!/usr/bin/env bash
# Merge a task's PR only when a clear crosscheck ledger covers the exact live
# head and PR claims, while always recording pr= and any available pr_head=.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crewmate's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording and crosscheck verification part of the merge
# itself, so neither can be skipped by omission. Use it for every PR merge.
#
# The installed gh-axi `pr merge` surface has no expected-head option. This
# script instead uses the private GitHub merge primitive through
# bin/fm-crosscheck.sh, which repeats ledger verification and passes the exact
# reviewed SHA in the atomic merge request. A force-push between verification
# and the request makes GitHub reject the merge.
#
# Merge method defaults to squash. The supported optional arguments are
# --squash, --merge, --rebase, --method, --subject, --body, and --body-file.
# --auto and --delete-branch are refused because neither belongs to the atomic
# expected-head merge request.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <atomic merge options>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <atomic merge options>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <atomic merge options>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    if [[ "${BASH_REMATCH[1]}" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

parse_pr_url "$URL" || exit 1

MERGE_METHOD=squash
MERGE_TITLE=
MERGE_BODY=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash) MERGE_METHOD=squash ;;
    --merge) MERGE_METHOD=merge ;;
    --rebase) MERGE_METHOD=rebase ;;
    --method)
      [ "$#" -ge 2 ] || { echo "error: --method requires a value" >&2; exit 1; }
      MERGE_METHOD=$2
      shift
      ;;
    --method=*) MERGE_METHOD=${1#--method=} ;;
    --subject)
      [ "$#" -ge 2 ] || { echo "error: --subject requires a value" >&2; exit 1; }
      MERGE_TITLE=$2
      shift
      ;;
    --subject=*) MERGE_TITLE=${1#--subject=} ;;
    --body)
      [ "$#" -ge 2 ] || { echo "error: --body requires a value" >&2; exit 1; }
      MERGE_BODY=$2
      shift
      ;;
    --body=*) MERGE_BODY=${1#--body=} ;;
    --body-file)
      [ "$#" -ge 2 ] || { echo "error: --body-file requires a value" >&2; exit 1; }
      [ -f "$2" ] || { echo "error: merge body file is unavailable: $2" >&2; exit 1; }
      MERGE_BODY=$(cat "$2")
      shift
      ;;
    --body-file=*)
      BODY_FILE=${1#--body-file=}
      [ -f "$BODY_FILE" ] || { echo "error: merge body file is unavailable: $BODY_FILE" >&2; exit 1; }
      MERGE_BODY=$(cat "$BODY_FILE")
      ;;
    --repo|--repo=*|-R|-R?*)
      echo "error: extra merge args must not override the repository parsed from the PR URL (got: $1)" >&2
      exit 1
      ;;
    --auto|--delete-branch)
      echo "error: $1 is incompatible with an atomic expected-head merge" >&2
      exit 1
      ;;
    *)
      echo "error: unsupported atomic merge argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

case "$MERGE_METHOD" in
  merge|squash|rebase) ;;
  *) echo "error: merge method must be merge, squash, or rebase" >&2; exit 1 ;;
esac

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

REVIEWED_HEAD=$("$SCRIPT_DIR/fm-crosscheck.sh" verify "$ID" "$URL") || exit 1
[[ "$REVIEWED_HEAD" =~ ^[0-9a-f]{40}$ ]] || {
  echo "error: crosscheck did not return one exact reviewed SHA" >&2
  exit 1
}
grep -qxF "pr_head=$REVIEWED_HEAD" "$META" || {
  echo "error: fm-pr-check did not record the reviewed live head in $META" >&2
  exit 1
}

MERGE_COMMAND=("$SCRIPT_DIR/fm-crosscheck.sh" merge "$ID" "$URL" "$REVIEWED_HEAD" "$MERGE_METHOD")
[ -z "$MERGE_TITLE" ] || MERGE_COMMAND+=(--title "$MERGE_TITLE")
[ -z "$MERGE_BODY" ] || MERGE_COMMAND+=(--body "$MERGE_BODY")
"${MERGE_COMMAND[@]}"
