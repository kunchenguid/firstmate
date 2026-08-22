#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# A non-green PR requires --allow-red before the optional -- separator.
# When the task project is this Firstmate repository, or cannot be resolved to
# any repository, the PR body must carry a completed no-mistakes Review record.
# The rendered step summary is read the way the renderer writes it: any Review
# entry counts as completed unless its status is one of the fixed incomplete
# states, because the incomplete set is closed while new completed renderings
# (a finding count, an auto-fix result, a risk verdict) keep being added.
# Because that body is user-writable, the receipt records intent rather than
# proving that the review ran.
# A missing receipt requires --allow-missing-review under explicit captain
# authorization; before the merge attempt, the override is recorded in the
# task metadata and disclosed on stderr. An ordinary merge that needs no
# override instead clears a stale receipt before merging, and either write
# failing refuses the merge rather than landing an untrue audit record. The
# override is the missing_review_override_ts= line in state/<id>.meta, recorded
# before a missing-Review merge attempt and cleared by an ordinary merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-red] [--allow-missing-review] [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

trap fm_pr_meta_cleanup EXIT
trap 'exit 1' HUP INT TERM

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
ALLOW_RED=0
ALLOW_MISSING_REVIEW=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-red) ALLOW_RED=1; shift ;;
    --allow-missing-review) ALLOW_MISSING_REVIEW=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

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

git_common_dir_abs() {  # <working-tree>
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) (cd "$common" 2>/dev/null && pwd -P) ;;
    *) (cd "$repo/$common" 2>/dev/null && pwd -P) ;;
  esac
}

# "Cannot tell" is not "another project": an absent or unresolvable project=
# must take the Review guard, or a broken meta would silently disarm it.
firstmate_review_receipt_required() {
  local project root_common project_common
  project=$(sed -n 's/^project=//p' "$META" | tail -n 1)
  root_common=$(git_common_dir_abs "$FM_ROOT") || root_common=
  project_common=
  if [ -n "$project" ]; then
    project_common=$(git_common_dir_abs "$project") || project_common=
  fi
  if [ -z "$root_common" ] || [ -z "$project_common" ]; then
    echo "warning: could not resolve this task's project as a repository; requiring a Firstmate no-mistakes Review record" >&2
    return 0
  fi
  [ "$project_common" = "$root_common" ]
}

firstmate_review_recorded() {
  local out
  # shellcheck disable=SC2016  # $body and $states are jq variables, not shell ones.
  out=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" --jq '
    (.body // "") as $body
    | [ $body | scan("<summary>[^<]*\\*\\*Review\\*\\* - ([^<]*)</summary>") | .[0] ] as $states
    | ($states | length) > 0
      and ($states | all(test("^(pending|running|auto-fixing|review fix|skipped|failed|awaiting approval|findings unavailable)$") | not))
  ' 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  printf '%s\n' "$out" | grep -qx true
}

merge_meta_identity_matches() {
  [ "$FM_PR_META_URL" = "$URL" ]
}

record_missing_review_override() {
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  fm_pr_meta_rewrite "$META" "$STATE" .fm-pr-merge-meta \
    missing_review_override_ts \
    merge_meta_identity_matches "missing_review_override_ts=$timestamp"
}

clear_missing_review_override() {
  fm_pr_meta_rewrite "$META" "$STATE" .fm-pr-merge-meta \
    missing_review_override_ts \
    merge_meta_identity_matches
}

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

MISSING_REVIEW_OVERRIDE=0
if firstmate_review_receipt_required && ! firstmate_review_recorded; then
  if [ "$ALLOW_MISSING_REVIEW" -ne 1 ]; then
    echo "error: refusing Firstmate merge without a recorded passing no-mistakes Review; pass --allow-missing-review only with explicit captain authorization" >&2
    exit 1
  fi
  MISSING_REVIEW_OVERRIDE=1
fi

CHECKS_OUTPUT=
MERGEABLE_OUTPUT=
CHECKS_GREEN=0
MERGEABLE_GREEN=0
if CHECKS_OUTPUT=$(gh-axi pr checks "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>&1); then
  if printf '%s\n' "$CHECKS_OUTPUT" \
    | grep -Eq '^summary: "[0-9]+ passed, 0 failed(, [0-9]+ skipped)?, [1-9][0-9]* total"$'; then
    CHECKS_GREEN=1
  fi
fi
if MERGEABLE_OUTPUT=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
  --jq '.mergeable == true and .mergeable_state == "clean"' 2>&1); then
  if printf '%s\n' "$MERGEABLE_OUTPUT" | grep -qx true; then
    MERGEABLE_GREEN=1
  fi
fi

if { [ "$CHECKS_GREEN" -ne 1 ] || [ "$MERGEABLE_GREEN" -ne 1 ]; } \
  && [ "$ALLOW_RED" -ne 1 ]; then
  echo "error: refusing to merge non-green PR $URL; pass --allow-red only with captain authorization" >&2
  printf '%s\n' "$CHECKS_OUTPUT" "$MERGEABLE_OUTPUT" >&2
  exit 1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if [ "$MISSING_REVIEW_OVERRIDE" -eq 1 ]; then
  record_missing_review_override || {
    echo "error: could not record the captain-authorized missing-Review override" >&2
    exit 1
  }
  echo "warning: captain-authorized override: merging Firstmate PR without a recorded passing no-mistakes Review" >&2
elif grep -q '^missing_review_override_ts=' "$META"; then
  clear_missing_review_override || {
    echo "error: could not clear the stale missing-Review override receipt" >&2
    exit 1
  }
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
