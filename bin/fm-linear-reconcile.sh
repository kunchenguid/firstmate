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

json_ok() {
  jq -e '.ok == true and (.result | type == "object")' >/dev/null 2>&1
}

issue_list_ok() {
  jq -e '.ok == true
    and (.result.issues | type == "array")
    and (.result.meta.partial != true)
    and ((.result.meta.workspaceErrors // []) | length == 0)' >/dev/null 2>&1
}

list_workspaces() {
  local response
  response=$("$LINEAR_CLI" linear team list --workspace all --json) \
    || die 'could not enumerate connected Linear workspaces'
  printf '%s\n' "$response" | json_ok \
    || die 'Linear workspace enumeration returned an invalid response'
  printf '%s\n' "$response" \
    | jq -r '.result.teams[]? | (.workspaceId // .workspace.id // empty)' \
    | awk 'NF && !seen[$0]++'
}

reconcile_workspace() {
  local workspace=$1 cursor response next_cursor issue issue_id updated_at count
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
      || die "Linear bug listing returned an invalid response for workspace $workspace"

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
      '.result.issues[]?
      | select(.state.type != "completed" and .state.type != "canceled")
      | {id, updatedAt}')

    next_cursor=$(printf '%s\n' "$response" | jq -r \
      'if .result.meta.hasMore == true then (.result.meta.nextCursor // empty) else empty end') \
      || die 'could not read Linear pagination metadata'
    [ -n "$next_cursor" ] || break
    [ "$next_cursor" != "$cursor" ] || die "Linear pagination did not advance for workspace $workspace"
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
  [ -n "$workspace" ] || continue
  workspace_count=$((workspace_count + 1))
  count=$(reconcile_workspace "$workspace") || exit 1
  issue_count=$((issue_count + count))
done <<< "$workspaces"
printf 'reconciled: workspaces=%s issues=%s consumption=active-supervisor-required\n' \
  "$workspace_count" "$issue_count"
