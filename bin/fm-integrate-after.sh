#!/usr/bin/env bash
# Integration-only task dependency, stored as `integrate-after: <task-id>` lines
# in the consumer's existing tasks-axi body. Unlike `blocked-by`, this relation
# never prevents dispatch or implementation. The PR and local landing commands
# call `check` under their task control lock and refuse until each provider is
# Done or its recorded PR has a confirmed merge notification. A missing or unreadable provider fails closed. Legacy tasks with no such
# lines remain ready; existing `blocked-by` relations keep their old meaning.
#
# Usage: fm-integrate-after.sh add <consumer-id> <provider-id>
#        fm-integrate-after.sh remove <consumer-id> <provider-id>
#        fm-integrate-after.sh check <consumer-id>
#        fm-integrate-after.sh --help
# `add` and `remove` preserve all unrelated body text and are idempotent.
# A provider archived out of tasks-axi's visible Done list is not guessed to
# have landed: remove its relation only after verifying its landing evidence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
fail() { printf 'fm-integrate-after: %s\n' "$*" >&2; exit 2; }
valid_id() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; }

case "${1:-}" in -h|--help) usage; exit 0 ;; add|remove|check) action=$1 ;; *) fail 'expected add, remove, or check' ;; esac
if [ "$action" = check ]; then [ "$#" -eq 2 ] || fail 'check needs one task id'; else [ "$#" -eq 3 ] || fail "$action needs consumer and provider ids"; fi
consumer=$2
valid_id "$consumer" || fail "invalid consumer id: $consumer"
if [ "$action" != check ]; then
  provider=$3
  valid_id "$provider" || fail "invalid provider id: $provider"
  [ "$consumer" != "$provider" ] || fail 'a task cannot integrate after itself'
fi
if [ "$action" = check ]; then
  gate_status=0
  fm_backlog_transition_applies "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$DATA" ship || gate_status=$?
  case "$gate_status" in
    0) ;;
    1) printf 'integration-ready: %s (%s)\n' "$consumer" "$FM_BACKLOG_TRANSITION_SKIP"; exit 0 ;;
    *) fail "cannot inspect integration dependencies: $FM_BACKLOG_TRANSITION_ERROR" ;;
  esac
fi
command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is not on PATH'

show_row() { fm_backlog_row_show "$DATA" "$1" --full; }
provider_merge_confirmed() {  # <provider-id>
  local id=$1 meta="$STATE/$1.meta" url
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  url=$(sed -n 's/^pr=//p' "$meta" | tail -1)
  [ -n "$url" ] && fm_pr_url_parse "$url" || return 1
  fm_pr_poll_merge_already_notified "$STATE" "$id" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
}
if row=$(show_row "$consumer"); then
  :
elif [ "$action" = check ] && printf '%s\n' "$row" | grep -qx 'code: NOT_FOUND'; then
  printf 'integration-ready: %s (legacy task has no backlog row)\n' "$consumer"
  exit 0
else
  fail "cannot read consumer $consumer: ${row%%$'\n'*}"
fi
body_json=$(printf '%s\n' "$row" | sed -n 's/^  body: //p' | head -1)
[ -n "$body_json" ] || fail "consumer $consumer has no readable body field"
body=$(printf '%s\n' "$body_json" | perl -MJSON::PP -e 'local $/; my $v=<STDIN>; $v =~ s/\s+\z//; $v=JSON::PP->new->utf8->allow_nonref->decode($v) if $v =~ /\A"/; binmode STDOUT, ":raw"; utf8::encode($v) if utf8::is_utf8($v); print $v unless $v eq "-"') \
  || fail "cannot decode consumer $consumer body"

# Accept the canonical body relation and the early no-space spelling. A
# malformed relation is never silently ignored at landing.
relations=$(printf '%s\n' "$body" | sed -nE 's/^integrate-after:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p')
if printf '%s\n' "$body" | grep -E '^integrate-after:' | grep -Ev '^integrate-after:[[:space:]]*[a-zA-Z0-9][a-zA-Z0-9._-]*[[:space:]]*$' >/dev/null; then
  fail "consumer $consumer has a malformed integrate-after relation"
fi

if [ "$action" = check ]; then
  [ -n "$relations" ] || { printf 'integration-ready: %s (no integration-only dependencies)\n' "$consumer"; exit 0; }
  while IFS= read -r provider; do
    [ -n "$provider" ] || continue
    valid_id "$provider" || fail "invalid provider id in $consumer: $provider"
    provider_row=$(show_row "$provider") || fail "provider $provider is unavailable; verify its landing and remove the relation explicitly"
    provider_state=$(printf '%s\n' "$provider_row" | sed -n 's/^  state: *//p' | head -1)
    [ "$provider_state" = 'done' ] || provider_merge_confirmed "$provider" \
      || fail "consumer $consumer must integrate after $provider; provider state is ${provider_state:-unreadable} with no confirmed merge"
  done <<< "$relations"
  printf 'integration-ready: %s (provider landing confirmed)\n' "$consumer"
  exit 0
fi

provider_row=$(show_row "$provider") || fail "cannot read provider $provider: ${provider_row%%$'\n'*}"
[ -n "$provider_row" ] || fail "provider $provider is unavailable"
if [ "$action" = add ]; then
  if printf '%s\n' "$relations" | grep -qxF "$provider"; then
    printf 'unchanged: %s integrates after %s\n' "$consumer" "$provider"
    exit 0
  fi
  new_body="${body}${body:+$'\n'}integrate-after: $provider"
else
  if ! printf '%s\n' "$relations" | grep -qxF "$provider"; then
    printf 'unchanged: %s has no integration relation to %s\n' "$consumer" "$provider"
    exit 0
  fi
  new_body=$(printf '%s\n' "$body" | awk -v provider="$provider" '
    /^integrate-after:/ {
      value=substr($0, 17)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value == provider) next
    }
    {print}
  ')
fi
tmp=$(mktemp "${TMPDIR:-/tmp}/fm-integrate-after.XXXXXX") || fail 'cannot stage task body'
trap 'rm -f "$tmp"' EXIT
printf '%s' "$new_body" > "$tmp"
FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" update "$consumer" --body-file "$tmp" >/dev/null \
  || fail "could not update consumer $consumer"
printf '%s: %s integrates after %s\n' "$action" "$consumer" "$provider"
