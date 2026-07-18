#!/usr/bin/env bash
# fm-lavish-review.sh - open a private Lavish review and arm FirstMate feedback polling.
#
# This is the FirstMate entrypoint for supervised Lavish visual reviews.
# It preserves the exact Lavish environment used to open the review, registers a
# trusted watcher check for the task, and keeps artifacts local to the current
# machine or trusted network.
# It never calls `lavish-axi share` and never publishes the artifact publicly.
#
# Usage:
#   fm-lavish-review.sh <task-id> <html-file> [-- <lavish-axi-open-arg>...]
#   fm-lavish-review.sh --arm-only <task-id> <html-file>
#   fm-lavish-review.sh --check-input <html-file>
#
# Use the first form instead of raw `lavish-axi <html-file>` for review tasks
# that FirstMate supervises.
# Pass `--` and normal open flags such as `--no-open`, `--no-gate`, or `--reopen`
# through to `lavish-axi` when needed.
# Use `--arm-only` only when the Lavish session was already opened with the same
# LAVISH_AXI_* environment currently in this shell.
#
# Structured-input rule:
# run `lavish-axi playbook input` before writing artifacts that collect choices.
# Controls that only stage feedback may call `window.lavish.queuePrompt()` and
# must visibly tell the reviewer to use Lavish's Send to Agent control.
# Controls that claim to send, submit, or finish feedback must call
# `window.lavish.sendQueuedPrompts()` after queueing the committed prompt.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

shell_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

canonical_file() {
  local raw=$1 dir base
  dir=$(cd "$(dirname "$raw")" && pwd -P) || return 1
  base=$(basename "$raw")
  printf '%s/%s\n' "$dir" "$base"
}

lavish_state_dir_value() {
  local value
  if [ "${LAVISH_AXI_STATE_DIR+x}" = x ] && [ -n "$LAVISH_AXI_STATE_DIR" ]; then
    case "$LAVISH_AXI_STATE_DIR" in
      /*) value=$LAVISH_AXI_STATE_DIR ;;
      *) value="$(pwd -P)/$LAVISH_AXI_STATE_DIR" ;;
    esac
  else
    value="$HOME/.lavish-axi"
  fi
  printf '%s\n' "$value"
}

lavish_host_value() {
  if [ "${LAVISH_AXI_HOST+x}" = x ] && [ -n "$LAVISH_AXI_HOST" ]; then
    printf '%s\n' "$LAVISH_AXI_HOST"
  else
    printf '%s\n' 127.0.0.1
  fi
}

lavish_link_host_value() {
  local host
  if [ "${LAVISH_AXI_LINK_HOST+x}" = x ] && [ -n "$LAVISH_AXI_LINK_HOST" ]; then
    printf '%s\n' "$LAVISH_AXI_LINK_HOST"
    return 0
  fi
  host=$(lavish_host_value)
  case "$host" in
    0.0.0.0) printf '%s\n' 127.0.0.1 ;;
    ::) printf '%s\n' ::1 ;;
    *) printf '%s\n' "$host" ;;
  esac
}

lavish_port_value() {
  if [ "${LAVISH_AXI_PORT+x}" = x ] && [ -n "$LAVISH_AXI_PORT" ]; then
    printf '%s\n' "$LAVISH_AXI_PORT"
  else
    printf '%s\n' 4387
  fi
}

lavish_env_value() {
  case "$1" in
    LAVISH_AXI_STATE_DIR) lavish_state_dir_value ;;
    LAVISH_AXI_HOST) lavish_host_value ;;
    LAVISH_AXI_LINK_HOST) lavish_link_host_value ;;
    LAVISH_AXI_PORT) lavish_port_value ;;
    *) return 1 ;;
  esac
}

lavish_input_check() {
  local file=$1 source
  source=$(LC_ALL=C tr -d '\r' < "$file" 2>/dev/null || true)
  printf '%s\n' "$source" | grep -Eq 'window[[:space:]]*\.[[:space:]]*lavish[[:space:]]*\.[[:space:]]*queuePrompt[[:space:]]*\(' || return 0
  if printf '%s\n' "$source" | grep -Eq 'window[[:space:]]*\.[[:space:]]*lavish[[:space:]]*\.[[:space:]]*sendQueuedPrompts[[:space:]]*\('; then
    return 0
  fi
  if printf '%s\n' "$source" | grep -Eqi 'Send[[:space:]]+(to|queued|feedback|prompt)|queued[[:space:]]+for[[:space:]]+(Lavish[[:space:]]+)?Send|press[[:space:]]+Send'; then
    printf 'LAVISH_INPUT_NOTICE: %s queues prompts and relies on an explicit visible Send action.\n' "$file" >&2
    return 0
  fi
  printf 'LAVISH_INPUT_ERROR: %s calls window.lavish.queuePrompt() without window.lavish.sendQueuedPrompts() or visible Send-to-Agent instructions.\n' "$file" >&2
  printf 'LAVISH_INPUT_ERROR: Controls that claim to send, submit, or finish feedback must call sendQueuedPrompts() after queuePrompt().\n' >&2
  printf 'LAVISH_INPUT_ERROR: Queue-only controls must visibly tell the reviewer to press Lavish Send to Agent.\n' >&2
  printf '%s\n' "LAVISH_INPUT_ERROR: Run \`lavish-axi playbook input\` for the current Lavish input contract." >&2
  return 1
}

write_env_record() {
  local id=$1 html=$2 check=$3 trust=$4 record tmp name env_value
  record="$DATA/$id/lavish-review.env"
  tmp="$record.tmp.$$"
  {
    printf 'recorded_at=%s\n' "$(shell_quote "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
    printf 'artifact=%s\n' "$(shell_quote "$html")"
    printf 'check=%s\n' "$(shell_quote "$check")"
    printf 'trust=%s\n' "$(shell_quote "$trust")"
    for name in LAVISH_AXI_STATE_DIR LAVISH_AXI_HOST LAVISH_AXI_LINK_HOST LAVISH_AXI_PORT; do
      env_value=$(lavish_env_value "$name")
      printf '%s=%s\n' "$name" "$(shell_quote "$env_value")"
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$record" || { rm -f -- "$tmp"; return 1; }
}

write_check() {
  local id=$1 html=$2 check=$3 trust=$4 tmp env_value existing name
  mkdir -p "$STATE" "$DATA/$id" || return 1
  if [ -e "$check" ] || [ -L "$check" ]; then
    existing=$(head -2 "$check" 2>/dev/null || true)
    case "$existing" in
      *fm-lavish-review-check-v1*) : ;;
      *) echo "error: $check already exists and is not a Lavish review check" >&2; return 1 ;;
    esac
  fi
  if [ -e "$STATE/$id.pr-poll" ] || [ -e "$STATE/$id.pr-poll-registration" ]; then
    echo "error: task $id already has a PR poll check; use a separate task id for the Lavish review" >&2
    return 1
  fi
  tmp=$(mktemp "$STATE/.fm-lavish-check.XXXXXX") || return 1
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# fm-lavish-review-check-v1'
    printf '%s\n' 'set -eu'
    printf '%s\n' 'unset LAVISH_AXI_STATE_DIR LAVISH_AXI_HOST LAVISH_AXI_LINK_HOST LAVISH_AXI_PORT LAVISH_AXI_NO_OPEN'
    for name in LAVISH_AXI_STATE_DIR LAVISH_AXI_HOST LAVISH_AXI_LINK_HOST LAVISH_AXI_PORT; do
      env_value=$(lavish_env_value "$name")
      printf 'export %s=%s\n' "$name" "$(shell_quote "$env_value")"
    done
    printf 'export FM_HOME=%s\n' "$(shell_quote "$FM_HOME")"
    printf 'export FM_ROOT_OVERRIDE=%s\n' "$(shell_quote "$FM_ROOT")"
    printf 'export FM_STATE_OVERRIDE=%s\n' "$(shell_quote "$STATE")"
    printf 'export FM_DATA_OVERRIDE=%s\n' "$(shell_quote "$DATA")"
    printf 'export FM_LAVISH_SOURCE_CHECK=%s\n' "$(shell_quote "$check")"
    printf 'export FM_LAVISH_SOURCE_TRUST=%s\n' "$(shell_quote "$trust")"
    printf 'exec %s %s %s\n' \
      "$(shell_quote "$SCRIPT_DIR/fm-lavish-poll.sh")" \
      "$(shell_quote "$id")" \
      "$(shell_quote "$html")"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$check" || { rm -f -- "$tmp"; return 1; }
  "$SCRIPT_DIR/fm-check-register.sh" "$id" >/dev/null || { rm -f -- "$check"; return 1; }
  write_env_record "$id" "$html" "$check" "$trust" || { rm -f -- "$check" "$trust"; return 1; }
}

ARM_ONLY=0
CHECK_INPUT_ONLY=0
OPEN_ARGS=()

case "${1:-}" in
  --arm-only)
    ARM_ONLY=1
    shift
    ;;
  --check-input)
    CHECK_INPUT_ONLY=1
    shift
    ;;
esac

if [ "$CHECK_INPUT_ONLY" -eq 1 ]; then
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  HTML=$(canonical_file "$1") || { echo "error: cannot resolve $1" >&2; exit 1; }
  [ -f "$HTML" ] || { echo "error: file not found: $HTML" >&2; exit 1; }
  lavish_input_check "$HTML"
  exit 0
fi

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
ID=$1
HTML=$(canonical_file "$2") || { echo "error: cannot resolve $2" >&2; exit 1; }
shift 2
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }
[ -f "$HTML" ] || { echo "error: file not found: $HTML" >&2; exit 1; }
case "${1:-}" in
  --) shift; OPEN_ARGS=("$@") ;;
  '') OPEN_ARGS=() ;;
  *) echo "error: pass Lavish open arguments after --" >&2; exit 2 ;;
esac

lavish_input_check "$HTML"

if [ "$ARM_ONLY" -ne 1 ]; then
  lavish-axi "$HTML" "${OPEN_ARGS[@]+"${OPEN_ARGS[@]}"}"
fi

CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
write_check "$ID" "$HTML" "$CHECK" "$TRUST"
printf 'armed: state/%s.check.sh polls Lavish feedback for %s\n' "$ID" "$HTML"
printf 'next_step: keep this review private/local or Tailscale-only, then append a paused status for the external Lavish review wait.\n'
printf 'next_step: exact Lavish environment is stored in data/%s/lavish-review.env.\n' "$ID"
printf 'next_step: when feedback arrives, FirstMate wakes with a path under data/%s/lavish-feedback/.\n' "$ID"
