#!/usr/bin/env bash
# fm-linear-reconcile.sh - one-shot Linear bug reconciliation producer.
#
# Usage:
#   fm-linear-reconcile.sh
#   fm-linear-reconcile.sh --help
#
# Queries every workspace connected to Orca, enumerates active Bug-labeled
# issues, and passes each canonical issue UUID plus updatedAt revision through
# the typed external-event ingress. Run this command hourly from an existing
# operator scheduler; it does not install a timer or start supervision.
#
# Environment:
#   FM_HOME        operational home
#   FM_LINEAR_CLI  Orca CLI executable, default selected for this platform
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
INGRESS="$SCRIPT_DIR/fm-procevent-external-event.sh"

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-linear-reconcile: %s\n' "$1" >&2
  exit 1
}

linear_cli_default() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    printf '%s\n' "$ORCA_CLI_COMMAND"
  elif [ -n "${ORCA_DEV_REPO_ROOT:-}" ]; then
    printf '%s\n' orca-dev
  elif [ "$(uname -s)" = Linux ]; then
    printf '%s\n' orca-ide
  else
    printf '%s\n' orca
  fi
}

workspace_list_ok() {
  jq -e '.ok == true
    and (.result | type == "object")
    and (.result.teams | type == "array")
    and (.result.teams | length > 0)
    and (all(.result.teams[];
      ((.workspaceId // .workspace.id) | type == "string" and length > 0)))
    and (.result.partial != true)
    and (.result.meta.partial != true)
    and ((.result.workspaceErrors // []) | type == "array" and length == 0)
    and ((.result.meta.workspaceErrors // []) | type == "array" and length == 0)' \
    >/dev/null 2>&1
}

issue_list_ok() {
  jq -e '.ok == true
    and (.result.issues | type == "array")
    and (all(.result.issues[];
      (.id | type == "string" and length > 0)
      and (.updatedAt | type == "string" and length > 0)
      and (.state.type | type == "string")))
    and (.result.meta | type == "object")
    and (.result.meta.hasMore | type == "boolean")
    and (.result.partial != true)
    and (.result.meta.partial != true)
    and ((.result.workspaceErrors // []) | type == "array" and length == 0)
    and ((.result.meta.workspaceErrors // []) | type == "array" and length == 0)' \
    >/dev/null 2>&1
}

list_workspaces() {
  local response
  response=$("$LINEAR_CLI" linear team list --workspace all --json) \
    || die 'could not enumerate connected Linear workspaces'
  printf '%s\n' "$response" | workspace_list_ok \
    || die 'Linear workspace enumeration returned an invalid or partial response'
  printf '%s\n' "$response" \
    | jq -r '.result.teams[] | (.workspaceId // .workspace.id)' \
    | awk '!seen[$0]++'
}

reconcile_workspace() {
  local workspace=$1 cursor response has_more next_cursor issue issue_id updated_at count seen
  local -a seen_cursors=()
  cursor=
  count=0
  while :; do
    if [ -n "$cursor" ]; then
      response=$("$LINEAR_CLI" linear list-issues --label Bug --limit 250 \
        --order-by updatedAt --cursor "$cursor" --workspace "$workspace" --json) \
        || die "could not list Linear bugs for workspace $workspace"
    else
      response=$("$LINEAR_CLI" linear list-issues --label Bug --limit 250 \
        --order-by updatedAt --workspace "$workspace" --json) \
        || die "could not list Linear bugs for workspace $workspace"
    fi
    printf '%s\n' "$response" | issue_list_ok \
      || die "Linear bug listing returned an invalid or partial response for workspace $workspace"

    while IFS= read -r issue; do
      [ -n "$issue" ] || continue
      issue_id=$(printf '%s' "$issue" | jq -r '.id') \
        || die 'could not read Linear issue UUID'
      updated_at=$(printf '%s' "$issue" | jq -r '.updatedAt') \
        || die 'could not read Linear issue updatedAt'
      printf '%s' "$issue" \
        | FM_HOME="$FM_HOME" "$INGRESS" ingest-linear "$issue_id" "$updated_at" >/dev/null \
        || die "could not ingest Linear issue $issue_id at $updated_at"
      count=$((count + 1))
    done < <(printf '%s\n' "$response" | jq -c \
      '.result.issues[]
      | select(.state.type != "completed" and .state.type != "canceled")
      | {id, updatedAt}')

    has_more=$(printf '%s\n' "$response" | jq -r '.result.meta.hasMore') \
      || die 'could not read Linear pagination metadata'
    [ "$has_more" = true ] || break
    next_cursor=$(printf '%s\n' "$response" | jq -r '.result.meta.nextCursor // empty') \
      || die 'could not read Linear pagination cursor'
    [ -n "$next_cursor" ] \
      || die "Linear pagination cursor is missing for workspace $workspace"
    for seen in "${seen_cursors[@]}"; do
      [ "$next_cursor" != "$seen" ] \
        || die "Linear pagination repeated a cursor for workspace $workspace"
    done
    seen_cursors+=("$next_cursor")
    cursor=$next_cursor
  done
  printf '%s\n' "$count"
}

case ${1-} in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || die 'jq is required'
LINEAR_CLI=${FM_LINEAR_CLI:-$(linear_cli_default)}
case $LINEAR_CLI in *[[:space:]]*) die 'FM_LINEAR_CLI must name one executable path without arguments' ;; esac
command -v "$LINEAR_CLI" >/dev/null 2>&1 || die "Linear CLI is unavailable: $LINEAR_CLI"

workspaces=$(list_workspaces) || exit 1
[ -n "$workspaces" ] || die 'no connected Linear workspaces were found'
workspace_count=0
issue_count=0
while IFS= read -r workspace; do
  workspace_count=$((workspace_count + 1))
  count=$(reconcile_workspace "$workspace") || exit 1
  issue_count=$((issue_count + count))
done <<< "$workspaces"
printf 'reconciled: workspaces=%s issues=%s consumption=active-supervisor-required\n' \
  "$workspace_count" "$issue_count"
