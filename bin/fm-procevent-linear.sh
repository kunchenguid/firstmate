#!/usr/bin/env bash
# Read-only Linear GraphQL process-event adapter.
#
# Usage:
#   fm-procevent-linear.sh arm <config.json>
#   fm-procevent-linear.sh retire <config.json>
#   fm-procevent-linear.sh poll <config.json>
#   fm-procevent-linear.sh poll-once <config.json>
#   fm-procevent-linear.sh source-id <config.json>
#   fm-procevent-linear.sh classify <result-file>
#   fm-procevent-linear.sh terminal <result-file>
#   fm-procevent-linear.sh silent <result-file>
#   fm-procevent-linear.sh read <result-file>
#
# The adapter owns detection only. Every GraphQL document below is a named query,
# and the adapter has no mutation command or fallback writer. It records a private
# observation snapshot so an unchanged Linear response produces no process result,
# wake, or model call. The generic process-event runner owns durable capture after
# this command prints an event.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRAPHQL_URL="${FM_LINEAR_GRAPHQL_URL:-https://api.linear.app/graphql}"
POLL_INTERVAL="${FM_LINEAR_POLL_INTERVAL:-30}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

require_runtime() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  [ -n "${LINEAR_API_KEY:-}" ] || die "LINEAR_API_KEY is required"
  case "$POLL_INTERVAL" in
    ''|*[!0-9]*) die "FM_LINEAR_POLL_INTERVAL must be whole seconds: $POLL_INTERVAL" ;;
  esac
}

canonical_config() {
  local config=${1-} real
  [ -n "$config" ] || usage
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$config" 2>/dev/null) \
    || die "cannot resolve Linear poll config: $config"
  [ -f "$real" ] && [ ! -L "$real" ] || die "Linear poll config is not a regular file: $config"
  jq -e '
    .schema == "fm-linear-poll.v1"
    and (.projects | type == "array" and length > 0)
    and all(.projects[];
      (.linearProjectSlug | type == "string" and length > 0)
      and (.linearProjectName | type == "string" and length > 0)
      and (.firstmateProject | type == "string" and length > 0))
    and ((.allowIssues // []) | type == "array")
  ' "$real" >/dev/null 2>&1 || die "invalid Linear poll config: $config"
  printf '%s\n' "$real"
}

cmd_source_id() {
  local config real digest
  config=${1-}
  [ "$#" -eq 1 ] || usage
  real=$(canonical_config "$config") || exit 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')
  else
    digest=$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')
  fi
  printf 'linear-%s\n' "$digest"
}

snapshot_path() {
  local id=$1
  printf '%s/linear-poll/%s.snapshot.json\n' "$STATE" "$id"
}

graphql_query() { # <query> <variables-json>
  local query=$1 variables=$2 response
  response=$(curl -fsS -X POST "$GRAPHQL_URL" \
    -H "Authorization: $LINEAR_API_KEY" \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg query "$query" --argjson variables "$variables" \
      '{query:$query,variables:$variables}')") \
    || die "Linear GraphQL query failed"
  printf '%s' "$response" | jq -e '.errors == null and (.data | type == "object")' >/dev/null 2>&1 \
    || die "Linear GraphQL returned errors"
  printf '%s\n' "$response"
}

# shellcheck disable=SC2016 # GraphQL variables are literal dollar-prefixed names.
ISSUES_QUERY='query FirstmateLinearIssues($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $after: String) {
  issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
    nodes {
      id identifier title url updatedAt
      project { id name slugId }
      state { name type }
      inverseRelations(first: 50) { nodes { type issue { id identifier state { name type } } } }
    }
    pageInfo { hasNextPage endCursor }
  }
}'

# shellcheck disable=SC2016 # GraphQL variables are literal dollar-prefixed names.
COMMENTS_QUERY='query FirstmateLinearComments($issueId: String!, $first: Int!, $after: String) {
  issue(id: $issueId) {
    comments(first: $first, after: $after) {
      nodes { id createdAt updatedAt }
      pageInfo { hasNextPage endCursor }
    }
  }
}'

fetch_project_issues() { # <slug> <states-json>
  local slug=$1 states=$2 after='' page all='[]' variables
  while :; do
    variables=$(jq -cn --arg slug "$slug" --argjson states "$states" --arg after "$after" '
      {projectSlug:$slug,stateNames:$states,first:50,after:(if $after == "" then null else $after end)}')
    page=$(graphql_query "$ISSUES_QUERY" "$variables") || return 1
    all=$(jq -cn --argjson accumulated "$all" --argjson page "$page" \
      '$accumulated + ($page.data.issues.nodes // [])') || return 1
    [ "$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.hasNextPage // false')" = true ] || break
    after=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.endCursor // empty')
    [ -n "$after" ] || die "Linear issue pagination omitted endCursor"
  done
  printf '%s\n' "$all"
}

fetch_issue_comments() { # <issue-id>
  local issue_id=$1 after='' page all='[]' variables
  while :; do
    variables=$(jq -cn --arg issue "$issue_id" --arg after "$after" '
      {issueId:$issue,first:50,after:(if $after == "" then null else $after end)}')
    page=$(graphql_query "$COMMENTS_QUERY" "$variables") || return 1
    all=$(jq -cn --argjson accumulated "$all" --argjson page "$page" \
      '$accumulated + ($page.data.issue.comments.nodes // [])') || return 1
    [ "$(printf '%s' "$page" | jq -r '.data.issue.comments.pageInfo.hasNextPage // false')" = true ] || break
    after=$(printf '%s' "$page" | jq -r '.data.issue.comments.pageInfo.endCursor // empty')
    [ -n "$after" ] || die "Linear comment pagination omitted endCursor"
  done
  printf '%s\n' "$all"
}

poll_cycle() { # <config> <source-id>: prints one envelope only on change
  local config=$1 id=$2 snapshot previous='{"issues":{},"comments":{}}' first_observation=true
  local states allow project slug project_name fm_project issues issue issue_id comments
  local current events='[]' staged
  snapshot=$(snapshot_path "$id")
  if [ -f "$snapshot" ]; then
    jq -e '.issues | type == "object"' "$snapshot" >/dev/null 2>&1 \
      || die "invalid Linear poll snapshot: $snapshot"
    previous=$(jq -c . "$snapshot") || exit 1
    first_observation=false
  fi
  # Carry forward every previously observed issue/comment identity rather than
  # rebuilding from only this cycle's active-state issues: an issue that
  # leaves the active states and later returns must not look brand-new, or
  # its already-seen comments replay as fresh comment.detected events.
  current=$previous
  states=$(jq -c '.activeStates // ["Todo", "In Progress", "Blocked", "Human Review"]' "$config")
  allow=$(jq -c '.allowIssues // []' "$config")

  while IFS= read -r project; do
    slug=$(printf '%s' "$project" | jq -r '.linearProjectSlug')
    project_name=$(printf '%s' "$project" | jq -r '.linearProjectName')
    fm_project=$(printf '%s' "$project" | jq -r '.firstmateProject')
    issues=$(fetch_project_issues "$slug" "$states") || return 1
    while IFS= read -r issue; do
      [ -n "$issue" ] || continue
      issue_id=$(printf '%s' "$issue" | jq -r '.id')
      current=$(jq -cn --argjson current "$current" --argjson issue "$issue" \
        '$current | .issues[$issue.id] = {identifier:$issue.identifier,state:$issue.state.name,updatedAt:$issue.updatedAt,url:$issue.url}')
      comments=$(fetch_issue_comments "$issue_id") || return 1
      current=$(jq -cn --argjson current "$current" --argjson comments "$comments" '
        reduce $comments[] as $comment ($current;
          .comments[$comment.id] = {createdAt:$comment.createdAt,updatedAt:$comment.updatedAt})')

      if [ "$(printf '%s' "$issue" | jq -r '.state.name')" = Todo ] \
        && printf '%s' "$issue" | jq -e '
          [(.inverseRelations.nodes // [])[]
            | select((.type | ascii_downcase) == "blocks")
            | select((.issue.state.type | ascii_downcase) != "completed")
            | select((.issue.state.type | ascii_downcase) != "canceled")]
          | length == 0' >/dev/null \
        && { [ "$(printf '%s' "$allow" | jq 'length')" -eq 0 ] \
          || printf '%s' "$allow" | jq -e --arg identifier "$(printf '%s' "$issue" | jq -r '.identifier')" \
            'index($identifier) != null' >/dev/null; } \
        && ! printf '%s' "$previous" | jq -e --arg issue "$issue_id" '.issues[$issue] != null' >/dev/null; then
        events=$(jq -cn --argjson events "$events" --argjson issue "$issue" \
          --arg project "$project_name" --arg firstmateProject "$fm_project" '
          $events + [{eventType:"todo.detected",issueId:$issue.id,identifier:$issue.identifier,
            title:$issue.title,projectName:$project,firstmateProject:$firstmateProject,url:$issue.url,
            observedUpdatedAt:$issue.updatedAt}]')
      fi

      if [ "$first_observation" = false ]; then
        events=$(jq -cn --argjson events "$events" --argjson issue "$issue" --argjson comments "$comments" \
          --argjson previous "$previous" --arg project "$project_name" --arg firstmateProject "$fm_project" '
          reduce ($comments[] | select($previous.comments[.id] == null)) as $comment ($events;
            . + [{eventType:"comment.detected",issueId:$issue.id,identifier:$issue.identifier,
              commentId:$comment.id,projectName:$project,firstmateProject:$firstmateProject,url:$issue.url,
              commentCreatedAt:$comment.createdAt,commentUpdatedAt:$comment.updatedAt}])')
      fi
    done < <(printf '%s' "$issues" | jq -c '.[]')
  done < <(jq -c '.projects[]' "$config")

  mkdir -p "$(dirname "$snapshot")" || die "cannot create Linear poll state directory"
  staged=$(mktemp "$(dirname "$snapshot")/.snapshot.XXXXXX") || die "cannot stage Linear poll snapshot"
  printf '%s\n' "$current" | jq -S . > "$staged" || { rm -f "$staged"; die "cannot write Linear poll snapshot"; }
  chmod 600 "$staged" 2>/dev/null || true
  mv "$staged" "$snapshot" || { rm -f "$staged"; die "cannot publish Linear poll snapshot"; }

  [ "$(printf '%s' "$events" | jq 'length')" -gt 0 ] || return 0
  jq -cn --arg schema fm-linear-event.v1 --arg source "$id" --argjson events "$events" \
    '{schema:$schema,sourceId:$source,events:$events}'
}

cmd_poll_once() {
  local config real id
  config=${1-}
  [ "$#" -eq 1 ] || usage
  require_runtime
  real=$(canonical_config "$config") || exit 1
  id=$(cmd_source_id "$real") || exit 1
  poll_cycle "$real" "$id"
}

cmd_poll() {
  local config real id result
  config=${1-}
  [ "$#" -eq 1 ] || usage
  require_runtime
  real=$(canonical_config "$config") || exit 1
  id=$(cmd_source_id "$real") || exit 1
  while :; do
    result=$(poll_cycle "$real" "$id") || return 1
    if [ -n "$result" ]; then
      printf '%s\n' "$result"
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done
}

cmd_arm() {
  local config real id
  config=${1-}
  [ "$#" -eq 1 ] || usage
  require_runtime
  real=$(canonical_config "$config") || exit 1
  id=$(cmd_source_id "$real") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register linear "$id" \
    -- "$SCRIPT_DIR/fm-procevent-linear.sh" poll "$real" || exit 1
  printf 'armed: %s\nconfig: %s\n' "$id" "$real"
}

cmd_retire() {
  local config=${1-} id
  [ "$#" -eq 1 ] || usage
  id=$(cmd_source_id "$config") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

cmd_classify() {
  jq -e '.schema == "fm-linear-event.v1" and (.events | length > 0)' "${1-}" >/dev/null 2>&1 \
    && printf 'changed\n' || printf 'unknown\n'
}

cmd_terminal() { return 1; }
cmd_silent() { return 1; }

cmd_read() {
  local file=${1-}
  [ -f "$file" ] || die "result file does not exist: $file"
  jq -r '
    "LINEAR EVENTS: \(.events | length)",
    (.events[] | "event_type: \(.eventType)\nidentifier: \(.identifier)\nproject: \(.projectName)\nurl: \(.url)" +
      (if .commentId then "\ncomment_id: \(.commentId)" else "" end))
  ' "$file"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  poll-once) shift; cmd_poll_once "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  silent) shift; cmd_silent "$@" ;;
  read) shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
