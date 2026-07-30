#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# A one-shot GitHub CI snapshot must contain only SUCCESS, SKIPPED, or NEUTRAL.
# A PR with no reported CI checks requires the explicit --no-ci-verified attestation.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--no-ci-verified] [-- <extra gh-axi pr merge args>]
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
NO_CI_VERIFIED=0
if [ "${1:-}" = --no-ci-verified ]; then
  NO_CI_VERIFIED=1
  shift
fi
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

reject_no_ci_attestation() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --no-ci-verified ]; then
      echo "error: --no-ci-verified must appear before --" >&2
      return 1
    fi
  done
}

reject_repo_overrides "$@" || exit 1
reject_no_ci_attestation "$@" || exit 1

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

CI_STATE_PREFIX='fm-pr-merge-ci-state:'
if ! check_states=$(gh pr view "$URL" --json statusCheckRollup --jq '
  if .statusCheckRollup == null then
    error("PR status check rollup is unavailable")
  elif (.statusCheckRollup | type) != "array" then
    error("PR status check rollup is invalid")
  else
    .statusCheckRollup[] |
    "fm-pr-merge-ci-state:" +
      (if .__typename == "CheckRun" then (.conclusion // .status // "")
      else (.state // "") end)
  end
'); then
  echo "error: cannot verify PR CI status" >&2
  exit 1
fi

if [ -z "$check_states" ]; then
  [ "$NO_CI_VERIFIED" -eq 1 ] || {
    echo "error: PR reports no CI checks; verify focused local checks and rerun with --no-ci-verified" >&2
    exit 1
  }
else
  while IFS= read -r check_state; do
    case "$check_state" in
      "$CI_STATE_PREFIX"*) check_state=${check_state#"$CI_STATE_PREFIX"} ;;
      *) echo "error: cannot verify PR CI status" >&2; exit 1 ;;
    esac
    case "$check_state" in
      SUCCESS|SKIPPED|NEUTRAL) ;;
      '') echo "error: PR CI returned an empty state" >&2; exit 1 ;;
      *) echo "error: PR CI is not green: $check_state" >&2; exit 1 ;;
    esac
  done <<EOF
$check_states
EOF
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
