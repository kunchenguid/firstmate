#!/usr/bin/env bash
# Inspect one canonical GitHub PR through gh-axi for manual supervision.
#
# This is the single owner of data-only PR inspection and pre-merge
# revalidation. It emits only validated scalar facts and never creates state
# artifacts or invokes a state-file check.
# Usage: fm-pr-inspect.sh <pr-url> [--expected-head <sha>] [--require-green]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then
  echo "error: usage: fm-pr-inspect.sh <pr-url> [--expected-head <sha>] [--require-green]" >&2
  exit 2
fi

RAW_URL=$1
shift
EXPECTED_HEAD=
REQUIRE_GREEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected-head)
      [ "$#" -gt 1 ] || { echo "error: --expected-head requires a SHA" >&2; exit 2; }
      EXPECTED_HEAD=$2
      shift 2
      ;;
    --require-green)
      REQUIRE_GREEN=1
      shift
      ;;
    *)
      echo "error: unknown inspection option: $1" >&2
      exit 2
      ;;
  esac
done

fm_pr_url_parse "$RAW_URL" || { echo "error: invalid PR URL" >&2; exit 1; }
[ "$FM_PR_PROVIDER" = github ] || { echo "error: unsupported forge for direct GitHub inspection" >&2; exit 1; }
[ -n "${EXPECTED_HEAD:-}" ] && fm_pr_head_valid "$EXPECTED_HEAD" \
  || [ -z "${EXPECTED_HEAD:-}" ] \
  || { echo "error: invalid expected PR head" >&2; exit 1; }
command -v gh-axi >/dev/null 2>&1 || { echo "error: gh-axi is unavailable" >&2; exit 1; }

fm_pr_api_jq_tsv() {
  local endpoint=$1 expression=$2 raw body
  raw=$(gh-axi api "$endpoint" --jq "$expression" 2>/dev/null) || return 1
  case "$raw" in
    $'api_response:\n  body: "'*$'"\n  truncated: false')
      body=${raw#*$'\n  body: "'}
      body=${body%$'"\n  truncated: false'}
      body=${body//\\t/$'\t'}
      ;;
    *$'\n'*|*'api_response:'*) return 1 ;;
    *) body=$raw ;;
  esac
  [ -n "$body" ] || return 1
  printf '%s\n' "$body"
}

PR_TSV=$(fm_pr_api_jq_tsv \
  "/repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" \
  '[.html_url,.head.sha,.state,(.merged|tostring),(.mergeable|tostring),.mergeable_state] | @tsv') \
  || { echo "error: GitHub PR query failed" >&2; exit 1; }
IFS=$'\t' read -r actual_url head_sha state merged mergeable mergeable_state extra <<< "$PR_TSV"
[ -z "${extra:-}" ] || { echo "error: GitHub PR identity response was ambiguous" >&2; exit 1; }
[ -n "$actual_url" ] && [ -n "$head_sha" ] && [ -n "$state" ] \
  && [ -n "$merged" ] && [ -n "$mergeable" ] && [ -n "$mergeable_state" ] \
  || { echo "error: GitHub PR identity response was incomplete" >&2; exit 1; }

[ "$actual_url" = "$FM_PR_URL" ] || { echo "error: GitHub returned an ambiguous PR identity" >&2; exit 1; }
fm_pr_head_valid "$head_sha" || { echo "error: GitHub returned an invalid PR head" >&2; exit 1; }
[ -z "${EXPECTED_HEAD:-}" ] || [ "$head_sha" = "$EXPECTED_HEAD" ] \
  || { echo "error: PR head changed from the recorded SHA" >&2; exit 1; }
status_tsv=$(fm_pr_api_jq_tsv \
  "/repos/$FM_PR_PATH/commits/$head_sha/status" \
  '[.state,(.total_count|tostring)] | @tsv') \
  || { echo "error: GitHub commit-status query failed" >&2; exit 1; }
IFS=$'\t' read -r status_state status_count status_extra <<< "$status_tsv"
[ -z "${status_extra:-}" ] && [[ "$status_count" =~ ^[0-9]+$ ]] \
  || { echo "error: GitHub commit-status response was ambiguous" >&2; exit 1; }

runs_tsv=$(fm_pr_api_jq_tsv \
  "/repos/$FM_PR_PATH/commits/$head_sha/check-runs" \
  '[(.total_count|tostring),([.check_runs[]|.status]|unique|join(",")),([.check_runs[]|(.conclusion // "")]|unique|join(","))] | @tsv') \
  || { echo "error: GitHub check-run query failed" >&2; exit 1; }
IFS=$'\t' read -r run_count run_statuses run_conclusions run_extra <<< "$runs_tsv"
[ -z "${run_extra:-}" ] && [[ "$run_count" =~ ^[0-9]+$ ]] \
  || { echo "error: GitHub check-run response was ambiguous" >&2; exit 1; }

checks=green
if [ "$status_count" -eq 0 ] && [ "$run_count" -eq 0 ]; then
  checks=none
else
  if [ "$status_count" -gt 0 ]; then
    case "$status_state" in
      success) ;;
      failure|error) checks=red ;;
      pending) checks=incomplete ;;
      *) checks=ambiguous ;;
    esac
  fi
  if [ "$run_count" -gt 0 ]; then
    [ -n "$run_statuses" ] && [ -n "$run_conclusions" ] || checks=ambiguous
    IFS=',' read -ra run_status_array <<< "$run_statuses"
    IFS=',' read -ra run_conclusion_array <<< "$run_conclusions"
    for run_status in "${run_status_array[@]}"; do
      case "$run_status" in
        completed) ;;
        queued|in_progress|waiting) checks=incomplete ;;
        *) checks=ambiguous ;;
      esac
    done
    for run_conclusion in "${run_conclusion_array[@]}"; do
      case "$run_conclusion" in
        success) ;;
        skipped) checks=ambiguous ;;
        *) checks=red ;;
      esac
    done
  fi
fi

[ "$state" = open ] && [ "$merged" = false ] \
  || { echo "error: PR is not an open, unmerged pull request" >&2; exit 1; }

if [ "$REQUIRE_GREEN" -eq 1 ]; then
  [ "$mergeable" = true ] && [ "$mergeable_state" = clean ] \
    || { echo "error: GitHub PR mergeability is not proven clean" >&2; exit 1; }
  case "$checks" in
    green|none) ;;
    red) echo "error: required GitHub checks are red" >&2; exit 1 ;;
    incomplete) echo "error: required GitHub checks are incomplete" >&2; exit 1 ;;
    *) echo "error: required GitHub checks are ambiguous" >&2; exit 1 ;;
  esac
fi

printf 'pr=%s\npr_head=%s\nmergeable=%s\nmergeable_state=%s\nchecks=%s\n' \
  "$FM_PR_URL" "$head_sha" "$mergeable" "$mergeable_state" "$checks"
