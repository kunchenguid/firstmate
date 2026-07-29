#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# --torn-down merges a PR whose task has already been cleaned up, so a late
# merge keeps the guarded path instead of reaching around it to a raw merge
# command. It requires the task metadata to be genuinely absent, refusing when
# the task is still live so it can never be used to skip recording or the merge
# poll for a task that has both. With no metadata to record into and no live
# task for a merge poll to wake, the merge is recorded in the durable ledger
# data/merged-prs.log as one <utc-timestamp><TAB><task-id><TAB><pr-url> line,
# written before the merge exactly as pr= is on the ordinary path.
# Usage: fm-pr-merge.sh [--torn-down] <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

TORN_DOWN=0
if [ "${1:-}" = "--torn-down" ]; then
  TORN_DOWN=1
  shift
fi

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
if [ "$TORN_DOWN" = 1 ]; then
  if [ -e "$META" ] || [ -L "$META" ]; then
    echo "error: task $ID still has metadata; merge it without --torn-down" >&2
    exit 1
  fi
  LEDGER="$DATA/merged-prs.log"
  mkdir -p "$DATA" || exit 1
  if [ -L "$LEDGER" ] || { [ -e "$LEDGER" ] && [ ! -f "$LEDGER" ]; }; then
    echo "error: merge ledger is unavailable" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$URL" >> "$LEDGER" || {
    echo "error: merge ledger recording failed" >&2
    exit 1
  }
  chmod 0600 "$LEDGER" || exit 1
else
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    echo "error: task metadata is unavailable" >&2
    exit 1
  fi

  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
