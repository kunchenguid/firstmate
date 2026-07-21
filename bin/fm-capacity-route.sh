#!/usr/bin/env bash
# Select conservative capacity routes and turn classified walls into rehome work.
# Usage:
#   fm-capacity-route.sh select [--routes-file <path>] [--dispatch-approved]
#   fm-capacity-route.sh handle-wall --task <id> --harness <h> [--account <a>] [--profile <p>] [--routes-file <path>] [--file <path>] [--dispatch-approved]
#
# Routes are read from key-value config lines:
#   route=<harness>|<account-or-provider>|<profile>|<model>|<effort>
#
# The helper never edits dispatch config, never creates a new task id, and never
# chooses an unverified harness.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"
# shellcheck source=bin/fm-harness-launch-lib.sh
. "$SCRIPT_DIR/fm-harness-launch-lib.sh"

usage() {
  sed -n '2,10p' "$0" >&2
}

need_value() {
  [ "$#" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

ROUTES_FILE="$CONFIG/capacity-failover"
DISPATCH_APPROVED=0
TASK_ID=
HARNESS=
ACCOUNT=
PROFILE=
FILE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --routes-file) need_value "$@"; ROUTES_FILE=$2; shift 2 ;;
    --routes-file=*) ROUTES_FILE=${1#--routes-file=}; shift ;;
    --dispatch-approved) DISPATCH_APPROVED=1; shift ;;
    --task) need_value "$@"; TASK_ID=$2; shift 2 ;;
    --task=*) TASK_ID=${1#--task=}; shift ;;
    --harness) need_value "$@"; HARNESS=$2; shift 2 ;;
    --harness=*) HARNESS=${1#--harness=}; shift ;;
    --account) need_value "$@"; ACCOUNT=$2; shift 2 ;;
    --account=*) ACCOUNT=${1#--account=}; shift ;;
    --profile) need_value "$@"; PROFILE=$2; shift 2 ;;
    --profile=*) PROFILE=${1#--profile=}; shift ;;
    --file) need_value "$@"; FILE=$2; shift 2 ;;
    --file=*) FILE=${1#--file=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

dispatch_backstop() {
  if [ -f "$CONFIG/crew-dispatch.json" ] && [ "$DISPATCH_APPROVED" -ne 1 ]; then
    echo "error: config/crew-dispatch.json is active; consult it first, then rerun with --dispatch-approved" >&2
    exit 1
  fi
}

routes() {
  [ -f "$ROUTES_FILE" ] || return 0
  awk -F= '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      k=$1
      sub(/^[[:space:]]+/, "", k)
      sub(/[[:space:]]+$/, "", k)
      if (k == "route") {
        v=$0
        sub(/^[^=]*=/, "", v)
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        print v
      }
    }
  ' "$ROUTES_FILE"
}

route_field() {  # <line> <index>
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '{ print $n }'
}

select_route() {
  local line idx harness account profile model effort selected=0 exhausted=0 active_out
  dispatch_backstop
  idx=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    idx=$((idx + 1))
    harness=$(route_field "$line" 1)
    account=$(route_field "$line" 2)
    profile=$(route_field "$line" 3)
    model=$(route_field "$line" 4)
    effort=$(route_field "$line" 5)
    [ -n "$profile" ] || profile=${model:-default}
    if ! fm_launch_template "$harness" ship >/dev/null 2>&1; then
      printf 'route_%s_status=unverified_harness\n' "$idx"
      printf 'route_%s_harness=%s\n' "$idx" "$harness"
      continue
    fi
    if active_out=$(fm_capacity_cooldown_active_for_route "$STATE" "$harness" "$account" "$profile" 2>/dev/null); then
      exhausted=$((exhausted + 1))
      printf 'route_%s_status=blocked\n' "$idx"
      printf 'route_%s_harness=%s\n' "$idx" "$harness"
      printf 'route_%s_account=%s\n' "$idx" "$account"
      printf 'route_%s_profile=%s\n' "$idx" "$profile"
      printf 'route_%s_model=%s\n' "$idx" "${model:-$profile}"
      printf 'route_%s_reason=%s\n' "$idx" "$(printf '%s\n' "$active_out" | sed -n 's/^reason=//p' | tail -1)"
      printf 'route_%s_reset_epoch=%s\n' "$idx" "$(printf '%s\n' "$active_out" | sed -n 's/^reset_epoch=//p' | tail -1)"
      printf 'route_%s_requires_action=%s\n' "$idx" "$(printf '%s\n' "$active_out" | sed -n 's/^requires_action=//p' | tail -1)"
      continue
    fi
    selected=1
    printf 'selected_harness=%s\n' "$harness"
    printf 'selected_account=%s\n' "$account"
    printf 'selected_profile=%s\n' "$profile"
    printf 'selected_model=%s\n' "${model:-$profile}"
    printf 'selected_effort=%s\n' "${effort:-default}"
    return 0
  done <<EOF
$(routes)
EOF
  if [ "$idx" -eq 0 ]; then
    printf 'escalation=capacity_routes_missing\n'
    printf 'needed_action=configure verified noninteractive route in %s\n' "$ROUTES_FILE"
  elif [ "$selected" -eq 0 ]; then
    printf 'escalation=every_verified_route_exhausted\n'
    printf 'exhausted_routes=%s\n' "$exhausted"
    printf 'needed_action=wait for reset or complete the listed interactive auth/account action\n'
  fi
  return 1
}

handle_wall() {
  local text classified class reason reset_epoch provider model account profile record selection status selected_harness selected_model selected_effort
  local blocked_reset_epoch blocked_requires_action
  [ -n "$TASK_ID" ] || { echo "error: handle-wall requires --task" >&2; exit 2; }
  [ -n "$HARNESS" ] || { echo "error: handle-wall requires --harness" >&2; exit 2; }
  # Refuse before any cooldown record is written; select_route runs inside a
  # command substitution, where its own backstop could only abort that subshell.
  dispatch_backstop
  if [ -n "$FILE" ]; then
    text=$(cat "$FILE")
  else
    text=$(cat)
  fi
  classified=$(fm_capacity_classify_text "$text")
  printf '%s\n' "$classified"
  class=$(printf '%s\n' "$classified" | sed -n 's/^class=//p' | tail -1)
  reason=$(printf '%s\n' "$classified" | sed -n 's/^reason=//p' | tail -1)
  reset_epoch=$(printf '%s\n' "$classified" | sed -n 's/^reset_epoch=//p' | tail -1)
  provider=$(printf '%s\n' "$classified" | sed -n 's/^provider=//p' | tail -1)
  model=$(printf '%s\n' "$classified" | sed -n 's/^model=//p' | tail -1)
  account=${ACCOUNT:-$provider}
  profile=${PROFILE:-${model:-default}}
  case "$class" in
    quota)
      [ -n "$reset_epoch" ] || { echo "error: quota wall has no observed reset; refusing to invent cooldown" >&2; exit 1; }
      record=$(fm_capacity_mark_cooldown "$STATE" "$HARNESS" "$account" "$profile" "$reset_epoch" "$class" "$reason" "$TASK_ID")
      blocked_reset_epoch=$reset_epoch
      blocked_requires_action=
      ;;
    auth)
      record=$(fm_capacity_mark_exhaustion "$STATE" "$HARNESS" "$account" "$profile" "$class" "$reason" "$TASK_ID" interactive_auth_required)
      blocked_reset_epoch=manual
      blocked_requires_action=interactive_auth_required
      ;;
    *)
      echo "error: wall class '$class' is not reroutable capacity/auth exhaustion" >&2
      exit 1
      ;;
  esac
  printf 'recorded_route_block=%s\n' "$record"
  if selection=$(select_route); then
    printf '%s\n' "$selection"
    selected_harness=$(printf '%s\n' "$selection" | sed -n 's/^selected_harness=//p' | tail -1)
    selected_model=$(printf '%s\n' "$selection" | sed -n 's/^selected_model=//p' | tail -1)
    selected_effort=$(printf '%s\n' "$selection" | sed -n 's/^selected_effort=//p' | tail -1)
    printf 'action=rehome_same_owner\n'
    printf 'task=%s\n' "$TASK_ID"
    printf 'rehome_command=%s/fm-rehome-quota-wall.sh %s --harness %s --model %s --effort %s --dispatch-approved\n' \
      "$SCRIPT_DIR" "$TASK_ID" "$selected_harness" "$selected_model" "$selected_effort"
    return 0
  else
    status=$?
    printf '%s\n' "$selection"
    printf 'action=escalate\n'
    printf 'task=%s\n' "$TASK_ID"
    printf 'blocked_harness=%s\n' "$HARNESS"
    printf 'blocked_account=%s\n' "$account"
    printf 'blocked_profile=%s\n' "$profile"
    printf 'blocked_model=%s\n' "${model:-$profile}"
    printf 'blocked_reset_epoch=%s\n' "$blocked_reset_epoch"
    printf 'blocked_requires_action=%s\n' "$blocked_requires_action"
    printf 'blocked_reason=%s\n' "$reason"
    return "$status"
  fi
}

case "$cmd" in
  select)
    select_route
    ;;
  handle-wall)
    handle_wall
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage
    exit 2
    ;;
esac
