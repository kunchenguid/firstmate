#!/usr/bin/env bash
# Static watcher probe for a yolo direct-PR task's recorded GitHub head.
# Emits "checks-green <check-set-sha256>" only for an open PR at that head,
# with a successful rollup, a readable base-branch required set whose every
# context passed at that head, and a nonempty check list with only pass/skipping
# buckets (all checks on fallback).
# The watcher deduplicates by head and check set, not head alone: a required
# check can first report after GitHub has already called the rollup SUCCESS.
# Errors and partial reads stay silent. This grants no merge authority;
# fm-pr-merge.sh still verifies all merge conditions live.
# Separate from fm-pr-poll.sh so armed merge polls remain byte-identical.
# Usage: fm-pr-green-poll.sh <github-pull-request-url> <head-sha>
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh" || exit 0

[ "$#" -eq 2 ] || exit 0
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 0
fm_pr_head_valid "$2" || exit 0
HEAD_SHA=$2

read_head() {
  # Owner and repository are raw strings, including all-digit names.
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state headRefOid baseRefName commits(last:1){nodes{commit{oid statusCheckRollup{state}}}}}}}' \
    -f "owner=$FM_PR_OWNER" -f "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER" \
    --jq '.data.repository.pullRequest | [.state, .headRefOid, .commits.nodes[0].commit.oid, .commits.nodes[0].commit.statusCheckRollup.state, .baseRefName] | map(. // "" | tostring) | join(" ")' \
    2>/dev/null
}
reading=$(read_head) || exit 0
[[ "$reading" = "OPEN $HEAD_SHA $HEAD_SHA SUCCESS "* ]] || exit 0
BASE_BRANCH=${reading#"OPEN $HEAD_SHA $HEAD_SHA SUCCESS "}
[ -n "$BASE_BRANCH" ] || exit 0

json=$(gh pr view "$FM_PR_URL" --json state,headRefOid,baseRefName,statusCheckRollup 2>/dev/null) || exit 0
green_json=$(printf '%s' "$json" | jq -ce --arg head "$HEAD_SHA" --arg base "$BASE_BRANCH" '
  select(.state == "OPEN" and .headRefOid == $head and .baseRefName == $base)
  | select((.statusCheckRollup | type) == "array")
  | .statusCheckRollup |= map(select(
      if .__typename == "CheckRun" then
        .status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")
      else .state == "SUCCESS" end))
' 2>/dev/null) || exit 0
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
github_read_required_contexts "$BASE_BRANCH" || exit 0
producers='[]'
if printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null; then
  producers=$(github_read_check_producers "$HEAD_SHA") || exit 0
fi
missing=$(github_required_checks_missing "$green_json" "$FM_PR_GITHUB_REQUIRED" "$producers") || exit 0
[ -z "$missing" ] || exit 0

if ! checks=$(gh pr checks "$FM_PR_URL" --required --json name,workflow,bucket 2>&1); then
  case "$checks" in
    "no required checks reported on the '"*"' branch")
      checks=$(gh pr checks "$FM_PR_URL" --json name,workflow,bucket 2>/dev/null) || exit 0
      ;;
    *) exit 0 ;;
  esac
fi
check_set=$(printf '%s\n' "$checks" | jq -ce '
  select(type == "array" and length > 0)
  | select(all(.[]; (.bucket == "pass" or .bucket == "skipping") and (.name | type == "string" and length > 0)))
  | map([(.workflow // ""), .name]) | unique
' 2>/dev/null) || exit 0
check_key=$(printf '%s\n' "$check_set" | fm_pr_sha256 -) || exit 0
[[ "$check_key" =~ ^[0-9a-f]{64}$ ]] || exit 0
# pr checks addresses a PR, not a SHA. Confirm it did not move or close while
# reading the checks before attaching their identity to the recorded head.
reading=$(read_head) || exit 0
[ "$reading" = "OPEN $HEAD_SHA $HEAD_SHA SUCCESS $BASE_BRANCH" ] || exit 0
printf 'checks-green %s\n' "$check_key"
