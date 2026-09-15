#!/usr/bin/env bash
# Audit every open GitHub pull request in one repository against the locally
# configured dressing rules, printing only violations.
#
# Usage: fm-pr-dressing-audit.sh <owner/repository>
#
# The configuration is config/pr-dressing-audit.json under FM_HOME.
# docs/configuration.md owns that schema and the scope this command does not
# claim to check.
#
# This is a committed script, not an agent's interactive operation.  It uses
# gh rather than gh-axi because gh provides stable machine-readable PR fields
# and explicit repository selection, neither available from gh-axi's PR interface.
# The command only reads forge state and never edits a pull request.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="$FM_HOME/config/pr-dressing-audit.json"

usage() {
  cat <<'EOF'
Usage: fm-pr-dressing-audit.sh <owner/repository>

Audit every open GitHub pull request in the named repository against its entry
in config/pr-dressing-audit.json.  The command is silent when every configured
rule passes and prints only violations otherwise.

It checks a configured integration branch, reviewer team, assignees,
mergeability, and configured required checks that are currently failing.
It does not infer branch protection, review approvals, merge authority, or
required checks absent from configuration.
EOF
}

die() {
  printf 'fm-pr-dressing-audit: %s\n' "$1" >&2
  exit 2
}

[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
REPO=$1
case "$REPO" in
  */*) ;;
  *) die 'repository must be owner/repository' ;;
esac

command -v gh >/dev/null 2>&1 || die 'gh not found'
command -v jq >/dev/null 2>&1 || die 'jq not found'
[ -f "$CONFIG" ] || die "configuration not found: $CONFIG"

if ! rules=$(jq -ce --arg repo "$REPO" '
    .repositories[$repo]
    | select(type == "object")
    | .integration_branch as $branch
    | .reviewer_team as $team
    | .assignees as $assignees
    | .required_checks as $checks
    | select(($branch | type) == "string" and ($branch | length) > 0)
    | select(($team | type) == "string" and ($team | test("^[^/[:space:]]+/[^/[:space:]]+$")))
    | select(($assignees | type) == "array" and all($assignees[]; type == "string" and length > 0))
    | select(($checks | type) == "array" and all($checks[]; type == "string" and length > 0))
  ' "$CONFIG" 2>/dev/null); then
  die "invalid or missing configuration for $REPO in $CONFIG"
fi

# Page size is 25: GitHub's GraphQL gateway times out (HTTP 504) on
# 100-pull-request pages carrying check rollups in busy repositories.
# shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
if ! pull_requests=$(gh api graphql --paginate --slurp \
    -f query='query($owner:String!,$repo:String!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequests(states:OPEN,first:25,after:$endCursor){nodes{number url baseRefName headRefName isCrossRepository mergeable assignees(first:100){nodes{login}} reviewRequests(first:100){nodes{requestedReviewer{__typename ... on Team{combinedSlug}}}} reviews(last:100){nodes{onBehalfOf(first:10){nodes{combinedSlug}}}} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{name status conclusion startedAt checkSuite{workflowRun{workflow{name}}}} ... on StatusContext{context state}}}}}}}} pageInfo{hasNextPage endCursor}}}}' \
    -f "owner=${REPO%%/*}" -f "repo=${REPO#*/}" 2>/dev/null) \
  || ! pull_requests=$(printf '%s' "$pull_requests" | jq -ce '[ .[].data.repository.pullRequests.nodes[] ]' 2>/dev/null); then
  die "could not read open pull requests for $REPO"
fi

printf '%s' "$pull_requests" | jq -r --argjson rules "$rules" '
  def check_is_failing:
    if .__typename == "CheckRun" then
      .status == "COMPLETED" and (.conclusion | IN("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"))
    elif .__typename == "StatusContext" then .state | IN("FAILURE", "ERROR")
    else false end;
  def check_name: if .__typename == "CheckRun" then .name else .context end;
  .[]
  | . as $pr
  | $pr.url as $url
  | (
      if $pr.baseRefName == "main" and $rules.integration_branch != "main" and ($pr.headRefName != $rules.integration_branch or $pr.isCrossRepository) then
        "\($url): base branch is main; expected \($rules.integration_branch)"
      else empty end
    ),
    (
      if ([ $pr.reviewRequests.nodes[]?.requestedReviewer | select(.__typename == "Team") | .combinedSlug ] + [ $pr.reviews.nodes[]?.onBehalfOf.nodes[].combinedSlug ] | index($rules.reviewer_team)) == null then
        "\($url): reviewer team missing: \($rules.reviewer_team)"
      else empty end
    ),
    (
      [ $rules.assignees[] | select(. as $login | ([ $pr.assignees.nodes[]?.login ] | index($login)) == null) ]
      | if length > 0 then "\($url): assignees missing: \(join(", "))" else empty end
    ),
    (
      if $pr.mergeable == "CONFLICTING" then
        "\($url): mergeable is CONFLICTING, not MERGEABLE"
      else empty end
    ),
    (
      $rules.required_checks[] as $required
      | [ $pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? | select(check_name == $required) ]
      | if any(group_by(.checkSuite.workflowRun.workflow.name)[] | max_by(.startedAt); check_is_failing) then
          "\($url): required check failing: \($required)"
        else empty end
    )
  '
