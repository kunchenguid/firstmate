#!/usr/bin/env bash
# Best-effort local Moshi webhook owner for captain-relevant lifecycle milestones.
#
# The opt-in token is read only from the effective home's private
# config/moshi-webhook-token file, which must be a readable regular file with no
# group or world read bit and must not be a symlink.
# The fixed Moshi endpoint is https://api.getmoshi.app/api/webhook.
# Missing or unsafe configuration, missing dependencies, request failures, and
# deduplication are all silent no-ops so notifications never break operations.
# The token is sent only in the webhook JSON payload and never appears in a
# durable marker, command output, or diagnostics.
#
# Source mode exposes these lifecycle owners:
#   fm_moshi_notify_pr_ready <task-id> <pr-url>
#   fm_moshi_notify_pr_merged <task-id> <pr-url>
#   fm_moshi_notify_attention <task-id> <needs-decision|blocked> <summary>
#   fm_moshi_notify_task_completed <task-id>
#
# CLI usage:
#   fm-moshi-notify.sh <pr-ready|pr-merged|attention|task-completed> <dedup-key> <title> <message>
#   fm-moshi-notify.sh --help
set -u

FM_MOSHI_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_MOSHI_WEBHOOK_ENDPOINT='https://api.getmoshi.app/api/webhook'
FM_MOSHI_TOKEN=

fm_moshi_usage() {
  printf '%s\n' \
    'Usage: fm-moshi-notify.sh <pr-ready|pr-merged|attention|task-completed> <dedup-key> <title> <message>' \
    '       fm-moshi-notify.sh --help' \
    '' \
    'Posts one concise JSON event to the fixed Moshi webhook when the private' \
    'effective-home config/moshi-webhook-token file is safe and present.'
}

fm_moshi_home() {
  local root
  root="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$FM_MOSHI_NOTIFY_DIR/.." && pwd)}}"
  printf '%s\n' "${FM_HOME:-$root}"
}

fm_moshi_state() {
  local home
  home=$(fm_moshi_home)
  printf '%s\n' "${FM_STATE_OVERRIDE:-$home/state}"
}

fm_moshi_config() {
  local home
  home=$(fm_moshi_home)
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

fm_moshi_token_path() {
  printf '%s/moshi-webhook-token\n' "$(fm_moshi_config)"
}

fm_moshi_token_safe() {
  local path=$1 mode padded
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path" 2>/dev/null) || return 1
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  padded=$(printf '%04s' "$mode" | tr ' ' 0) || return 1
  [ "${#padded}" -eq 4 ] || return 1
  case "${padded:2:1}${padded:3:1}" in
    *[4-7]*) return 1 ;;
  esac
  [ -r "$path" ]
}

fm_moshi_read_token() {
  local path=$1 token= extra=
  FM_MOSHI_TOKEN=
  fm_moshi_token_safe "$path" || return 1
  exec 3< "$path" 2>/dev/null || return 1
  if ! IFS= read -r token <&3; then
    [ -n "$token" ] || { exec 3<&-; return 1; }
  fi
  if IFS= read -r extra <&3; then
    exec 3<&-
    return 1
  fi
  exec 3<&-
  [ -z "$extra" ] || return 1
  case "$token" in
    ''|*$'\r'*|*$'\n'*) return 1 ;;
  esac
  FM_MOSHI_TOKEN=$token
}

fm_moshi_digest() {
  local event=$1 dedup_key=$2 input
  input=$(printf '%s\n%s' "$event" "$dedup_key")
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

fm_moshi_event_valid() {
  case "$1" in
    pr-ready|pr-merged|attention|task-completed) return 0 ;;
    *) return 1 ;;
  esac
}

fm_moshi_mark_once() {
  local state=$1 digest=$2 root marker
  root="$state/.moshi-notifications"
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
  else
    mkdir -p -m 700 "$root" 2>/dev/null || return 1
  fi
  marker="$root/$digest"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    return 1
  fi
  mkdir "$marker" 2>/dev/null
}

fm_moshi_notify() {
  local event=$1 dedup_key=$2 title=$3 message=$4 state token_path token digest
  local payload marker_dir
  fm_moshi_event_valid "$event" || return 0
  [ -n "$dedup_key" ] && [ -n "$title" ] && [ -n "$message" ] || return 0
  token_path=$(fm_moshi_token_path)
  fm_moshi_read_token "$token_path" || return 0
  token=$FM_MOSHI_TOKEN
  digest=$(fm_moshi_digest "$event" "$dedup_key") || return 0
  state=$(fm_moshi_state)
  [ -d "$state" ] || return 0
  title=${title:0:160}
  message=${message:0:512}
  command -v jq >/dev/null 2>&1 || return 0
  payload=$(jq -cn --arg token "$token" --arg title "$title" --arg message "$message" \
    '{token: $token, title: $title, message: $message}' 2>/dev/null) || return 0
  fm_moshi_mark_once "$state" "$digest" || return 0
  marker_dir="$state/.moshi-notifications/$digest"
  if curl --silent --show-error --fail --proto '=https' --tlsv1.2 \
    --connect-timeout 2 --max-time 5 --request POST \
    --header 'Content-Type: application/json' \
    --data-binary "$payload" \
    --output /dev/null "$FM_MOSHI_WEBHOOK_ENDPOINT" >/dev/null 2>&1; then
    return 0
  fi
  rmdir -- "$marker_dir" 2>/dev/null || true
  return 0
}

fm_moshi_notify_pr_ready() {
  local task_id=$1 pr_url=$2
  fm_moshi_notify pr-ready "pr-ready:$task_id:$pr_url" \
    'PR ready for review' "Task $task_id is ready for review: $pr_url"
}

fm_moshi_notify_pr_merged() {
  local task_id=$1 pr_url=$2
  fm_moshi_notify pr-merged "pr-merged:$task_id:$pr_url" \
    'PR merged' "Task $task_id PR was merged: $pr_url"
}

fm_moshi_notify_attention() {
  local task_id=$1 kind=$2 summary=$3 title
  case "$kind" in
    needs-decision) title='Firstmate decision needed' ;;
    blocked) title='Firstmate blocker needs attention' ;;
    *) return 0 ;;
  esac
  fm_moshi_notify attention "attention:$task_id:$kind:$summary" "$title" \
    "Task $task_id $kind: $summary"
}

fm_moshi_notify_task_completed() {
  local task_id=$1
  fm_moshi_notify task-completed "task-completed:$task_id" \
    'Task completed' "Task $task_id completed successfully after cleanup."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --help ]; then
    fm_moshi_usage
    exit 0
  fi
  if [ "$#" -ne 4 ] || ! fm_moshi_event_valid "$1"; then
    fm_moshi_usage >&2
    exit 2
  fi
  fm_moshi_notify "$1" "$2" "$3" "$4"
fi
