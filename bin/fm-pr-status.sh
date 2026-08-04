#!/usr/bin/env bash
# fm-pr-status.sh - normalize and cache a task PR's review, check, and
# mergeability state.
#
# A recorded PR URL alone does not tell a reader whether the work is waiting on
# review, waiting on checks, conflicting, or already merged. This script is the
# ONE place that asks a forge that question and the ONE place that maps each
# forge's vocabulary onto firstmate's normalized enumerations:
#
#   state      open | draft | closed | merged | unknown
#   review     approved | changes_requested | review_required | none | unknown
#   checks     passing | failing | pending | none | unknown
#   mergeable  mergeable | conflicting | blocked | unknown
#
# `refresh` is the only network caller. It writes the observation to the private
# cache at state/<task-id>.pr-status (schema fm-pr-status.v1), so read-only
# consumers - bin/fm-fleet-snapshot.sh and the outcome manifest - report a
# normalized state with an explicit observed_at and age instead of calling a
# forge themselves. A refresh that fails leaves the previous observation in
# place rather than overwriting a good reading with unknown.
#
# Only the enumerated tokens above, the PR identity already recorded by
# bin/fm-pr-check.sh, and a head SHA are ever stored. No raw API payload, no
# review body, no title, and no branch content reach disk.
#
# Usage:
#   fm-pr-status.sh refresh <task-id> [--url <pr-url>]
#   fm-pr-status.sh show <task-id>
#
# refresh resolves the PR URL from task metadata unless --url names one.
# GitHub is read through gh-axi, falling back to gh. GitLab merge requests are
# read through glab. An absent CLI, an unauthenticated CLI, or a request that
# exceeds FM_PR_STATUS_TIMEOUT (default 20s) is a soft failure: it exits nonzero
# with a one-line reason and changes nothing.
#
# docs/fleet-data-contracts.md owns field ownership and consumer guarantees.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-outcome-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-outcome-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

FM_PR_STATUS_TIMEOUT=${FM_PR_STATUS_TIMEOUT:-20}

usage() {
  cat <<'EOF'
usage: fm-pr-status.sh refresh <task-id> [--url <pr-url>]
       fm-pr-status.sh show <task-id>

refresh reads the task's PR from its forge and caches the normalized
review/check/mergeability observation at state/<task-id>.pr-status
(schema fm-pr-status.v1). It is the only network caller in this contract.
A failed refresh keeps the previous observation and exits nonzero.

show prints the cached document, or the unknown observation when none exists.

FM_PR_STATUS_TIMEOUT (default 20) bounds each forge call.
EOF
}

command -v jq >/dev/null 2>&1 || { echo "fm-pr-status: jq not found" >&2; exit 1; }

run_bounded() {  # <cmd...>
  if command -v timeout >/dev/null 2>&1; then
    timeout "$FM_PR_STATUS_TIMEOUT" "$@"
  else
    "$@"
  fi
}

github_cli() {
  if command -v gh-axi >/dev/null 2>&1; then
    printf 'gh-axi'
  elif command -v gh >/dev/null 2>&1; then
    printf 'gh'
  else
    return 1
  fi
}

# GitHub's own vocabulary, read through one bounded call and immediately reduced
# to the normalized tokens. statusCheckRollup is a list of check runs, so the
# rollup is folded here rather than stored.
refresh_github() {  # <owner/repo> <number> -> normalized fields on stdout
  local repo=$1 number=$2 cli raw
  cli=$(github_cli) || { echo "fm-pr-status: no gh-axi or gh on PATH" >&2; return 1; }
  raw=$(run_bounded "$cli" pr view "$number" --repo "$repo" --json \
    state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefOid,statusCheckRollup \
    2>/dev/null) || { echo "fm-pr-status: $cli could not read $repo#$number" >&2; return 1; }
  printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { echo "fm-pr-status: unusable response for $repo#$number" >&2; return 1; }
  printf '%s' "$raw" | jq -r '
    def rollup:
      ([.statusCheckRollup // [] | .[] | (.conclusion // .state // .status // "")] | map(ascii_downcase)) as $c
      | if ($c | length) == 0 then "none"
        elif ($c | any(. == "failure" or . == "error" or . == "timed_out"
                       or . == "cancelled" or . == "canceled" or . == "failing")) then "failure"
        elif ($c | any(. == "pending" or . == "in_progress" or . == "queued"
                       or . == "waiting" or . == "expected" or . == "")) then "pending"
        else "success" end;
    [(.state // ""), (.isDraft // false | tostring), (.mergeable // ""),
     (.mergeStateStatus // ""), (.reviewDecision // ""), (.headRefOid // ""), rollup]
    | @tsv'
}

# GitLab merge requests through glab. detailed_merge_status carries the
# conflict/blocked distinction; pipeline status carries the check rollup.
refresh_gitlab() {  # <host> <project-path> <number>
  local host=$1 path=$2 number=$3 raw
  command -v glab >/dev/null 2>&1 || { echo "fm-pr-status: no glab on PATH" >&2; return 1; }
  raw=$(GITLAB_HOST="$host" run_bounded glab api \
    "projects/$(printf '%s' "$path" | sed 's|/|%2F|g')/merge_requests/$number" 2>/dev/null) \
    || { echo "fm-pr-status: glab could not read $path!$number" >&2; return 1; }
  printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { echo "fm-pr-status: unusable response for $path!$number" >&2; return 1; }
  printf '%s' "$raw" | jq -r '
    [(.state // ""), (.draft // .work_in_progress // false | tostring),
     (.detailed_merge_status // .merge_status // ""),
     (.detailed_merge_status // .merge_status // ""),
     (if (.approvals_before_merge // 0) > 0 then "review_required" else "" end),
     (.sha // ""),
     (.head_pipeline.status // .pipeline.status // "")]
    | @tsv'
}

cmd_refresh() {  # <id> [--url <url>]
  local id=$1 url=''
  local meta="$STATE/$id.meta"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) [ "$#" -ge 2 ] || { usage >&2; return 2; }; url=$2; shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  if [ -z "$url" ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] || {
      echo "fm-pr-status: no task metadata for $id" >&2
      return 1
    }
    url=$(fm_outcome_kv_get "$meta" pr)
  fi
  [ -n "$url" ] || { echo "fm-pr-status: task $id has no recorded PR" >&2; return 1; }
  fm_pr_url_parse "$url" || { echo "fm-pr-status: unusable PR URL for $id" >&2; return 2; }

  local fields raw_state raw_draft raw_mergeable raw_merge_state raw_review raw_head raw_checks
  case "$FM_PR_PROVIDER" in
    github) fields=$(refresh_github "$FM_PR_PATH" "$FM_PR_NUMBER") || return 1 ;;
    gitlab) fields=$(refresh_gitlab "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER") || return 1 ;;
    *) echo "fm-pr-status: unsupported forge for $id" >&2; return 1 ;;
  esac
  IFS=$'\t' read -r raw_state raw_draft raw_mergeable raw_merge_state raw_review raw_head raw_checks \
    <<<"$fields"

  local merged=false
  case "$(printf '%s' "$raw_state" | tr '[:upper:]' '[:lower:]')" in
    merged) merged=true ;;
  esac
  local state draft review checks mergeable observed doc
  state=$(fm_outcome_pr_state_normalize "$raw_state" "$merged" "$raw_draft")
  case "$raw_draft" in true) draft=true ;; false) draft=false ;; *) draft= ;; esac
  review=$(fm_outcome_pr_review_normalize "$raw_review")
  checks=$(fm_outcome_pr_checks_normalize "$raw_checks")
  mergeable=$(fm_outcome_pr_mergeable_normalize "$raw_mergeable" "$raw_merge_state")
  observed=$(fm_outcome_now_iso)

  doc=$(fm_outcome_pr_status_doc \
    "$FM_PR_URL" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    "$state" "$draft" "$review" "$checks" "$mergeable" "$raw_head" "$observed" \
    "$FM_PR_PROVIDER") || {
    echo "fm-pr-status: could not compose the observation for $id" >&2
    return 1
  }
  fm_outcome_json_write "$(fm_outcome_pr_status_path "$STATE" "$id")" "$doc" || {
    echo "fm-pr-status: could not cache the observation for $id" >&2
    return 1
  }
  printf '%s\n' "$doc"
}

cmd_show() {  # <id>
  local doc
  if doc=$(fm_outcome_pr_status_doc_read "$STATE" "$1"); then
    printf '%s\n' "$doc"
    return 0
  fi
  jq -n --arg schema "$FM_PR_STATUS_SCHEMA" \
    --argjson status "$(fm_outcome_pr_status_unknown)" \
    '{schema:$schema,url:null,provider:null,host:null,path:null,number:null,status:$status}'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  refresh)
    shift
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    fm_pr_task_id_valid "$1" || { echo "fm-pr-status: invalid task id" >&2; exit 2; }
    cmd_refresh "$@"
    ;;
  show)
    shift
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_pr_task_id_valid "$1" || { echo "fm-pr-status: invalid task id" >&2; exit 2; }
    cmd_show "$1"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
