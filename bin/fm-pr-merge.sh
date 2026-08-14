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

merge_head_args=()
fm_state_mode_detect "$STATE"
if [ "$FM_STATE_MODE" = data-only ]; then
  unsafe=$(fm_state_data_only_artifacts "$STATE")
  [ -z "$unsafe" ] || {
    echo "error: data-only merge refuses pre-existing executable/check artifacts without executing them: $unsafe" >&2
    exit 1
  }
  fm_pr_metadata_identity_parse "$META" || {
    echo "error: data-only merge requires valid canonical PR metadata" >&2
    exit 1
  }
  [ "$FM_PR_META_PROVIDER" = github ] && [ "$FM_PR_META_URL" = "$URL" ] || {
    echo "error: data-only merge refuses unsupported forge or changed canonical PR URL" >&2
    exit 1
  }
  recorded_head=
  recorded_head_count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr_head=*)
        recorded_head=${line#pr_head=}
        recorded_head_count=$((recorded_head_count + 1))
        ;;
    esac
  done < "$META"
  [ "$recorded_head_count" -eq 1 ] && fm_pr_head_valid "$recorded_head" || {
    echo "error: data-only merge requires exactly one valid recorded PR head SHA" >&2
    exit 1
  }
  "$SCRIPT_DIR/fm-pr-inspect.sh" "$URL" --expected-head "$recorded_head" --require-green \
    >/dev/null || {
    echo "error: data-only merge refused because current GitHub PR identity, head, mergeability, or checks were not fully revalidated" >&2
    exit 1
  }
  merge_head_args=(--match-head-commit "$recorded_head")
else
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

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
  "${merge_args[@]+"${merge_args[@]}"}" "${merge_head_args[@]+"${merge_head_args[@]}"}" "$@"
