#!/usr/bin/env bash
# fm-decision-alert.sh - best-effort audible alerts for captain decisions.
#
# This script alerts only for a genuine unresolved `needs-decision` event or an
# explicit Firstmate prompt registered with a stable privacy-safe identity.
# Routine work, progress, blocked/paused/done events, and resolved decisions do
# not alert.
#
# Usage:
#   fm-decision-alert.sh decision <origin-id> <decision-key>
#   fm-decision-alert.sh prompt <origin-id> <decision-key>
#   fm-decision-alert.sh status <status-file>
#   fm-decision-alert.sh scan-state
#   fm-decision-alert.sh --help
#
# `decision` and `prompt` are equivalent identity registrations.
# Use `prompt` immediately before Firstmate asks the captain directly.
# Use the same origin and key as a matching decision hold or status event so
# repeated delivery converges on one alert attempt.
# `status` folds the whole append-only status stream and alerts for each still
# open needs-decision key, even when a later unrelated event follows it.
# `scan-state` applies that fold to every status file in the effective home.
#
# Config: config/decision-alert, one directive per non-empty, non-comment line.
# FM_DECISION_ALERT_CHANNEL overrides the file with a single directive.
# Directives are off, auto/default, osascript, herdr, and command:<cmd>.
# An absent config means auto, which resolves to an audible macOS Notification
# Center alert and no built-in channel on other platforms.
# `off` disables every channel without consuming the decision identity.
#
# FM_DECISION_ALERT_EXEC replaces every real notifier with a test command invoked
# as `<command> <channel> <body>`.
# The value `discard` performs no notifier execution.
# Sourcing this script defaults that seam to discard so library-mode tests can
# never post a real notification or play a real sound.
# FM_DECISION_ALERT_TIMEOUT_SECS bounds each channel and defaults to 10 seconds.
# FM_DECISION_ALERT_TOTAL_TIMEOUT_SECS bounds the complete invocation and
# defaults to 10 seconds.
# Up to eight notifier workers run concurrently within the shared invocation
# deadline.
#
# Deduplication uses state/.decision-alerted-<sha256(identity)>.
# Marker creation is atomic and occurs before notifier execution, so concurrent
# or repeated delivery attempts cannot double-alert.
# The marker contains no decision text or identity.
# Notifier failure is reported best-effort but always leaves the durable decision
# and alert marker intact, never grants approval, and never makes a caller fail.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DECISION_ALERT_TIMEOUT_SECS_DEFAULT=10
DECISION_ALERT_TOTAL_TIMEOUT_SECS_DEFAULT=10
DECISION_ALERT_MAX_WORKERS=8
DECISION_ALERT_TITLE='Firstmate needs your decision'
DECISION_ALERT_BODY='Return to Firstmate to review the decision.'
DECISION_ALERT_SOUND='Basso'
DECISION_ALERT_DEADLINE=
DECISION_ALERT_ORIGINS=()
DECISION_ALERT_KEYS=()
DECISION_ALERT_CHANNELS=()

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-notify-lib.sh
. "$SCRIPT_DIR/fm-notify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

decision_alert_log() {
  printf 'fm-decision-alert: %s\n' "$*" >&2
}

decision_alert_validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) decision_alert_log "$label must be a non-empty privacy-safe slug"; return 1 ;;
  esac
}

decision_alert_hash() {  # <privacy-safe-identity>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | cksum | awk '{print "cksum-" $1 "-" $2}'
  fi
}

decision_alert_configured_channels() {
  local cfg line found=
  if [ -n "${FM_DECISION_ALERT_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_DECISION_ALERT_CHANNEL"
    return 0
  fi
  cfg="$CONFIG/decision-alert"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

decision_alert_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

decision_alert_run_bounded() {  # <timeout> <channel> <command> [args...]
  local timeout=$1 channel=$2 rc
  shift 2
  fm_notify_run_bounded "$timeout" "$channel" "$@"
  rc=$?
  case "$rc" in
    124) decision_alert_log "$channel notifier timed out after ${FM_NOTIFY_LAST_ELAPSED}s" ;;
    125) decision_alert_log "$channel notifier skipped because its watchdog could not start" ;;
  esac
  return "$rc"
}

decision_alert_begin_budget() {
  local total
  total=${FM_DECISION_ALERT_TOTAL_TIMEOUT_SECS:-$DECISION_ALERT_TOTAL_TIMEOUT_SECS_DEFAULT}
  case "$total" in ''|*[!0-9]*|0) total=$DECISION_ALERT_TOTAL_TIMEOUT_SECS_DEFAULT ;; esac
  DECISION_ALERT_DEADLINE=$((SECONDS + total))
}

decision_alert_remaining_budget() {
  local remaining=$((DECISION_ALERT_DEADLINE - SECONDS))
  [ "$remaining" -gt 0 ] || return 1
  printf '%s\n' "$remaining"
}

decision_alert_claim() {  # <origin-id> <decision-key>
  local digest marker
  mkdir -p "$STATE" || return 1
  digest=$(decision_alert_hash "$1:$2") || return 1
  marker="$STATE/.decision-alerted-$digest"
  ( set -C; : > "$marker" ) 2>/dev/null
}

decision_alert_emit_channel() {  # <channel> <override> <timeout>
  local ch=$1 override=$2 timeout=$3 resolved_ch=$1 command_body='' rc
  if [ "${ch#command:}" != "$ch" ]; then
    resolved_ch='command'
    command_body=${ch#command:}
    fm_notify_emit decision_alert_run_bounded "$override" "$timeout" command \
      "$DECISION_ALERT_TITLE" "$DECISION_ALERT_BODY" "$DECISION_ALERT_SOUND" "$command_body"
  else
    fm_notify_emit decision_alert_run_bounded "$override" "$timeout" "$ch" \
      "$DECISION_ALERT_TITLE" "$DECISION_ALERT_BODY" "$DECISION_ALERT_SOUND"
  fi
  rc=$?
  [ "$rc" -eq 0 ] || decision_alert_log "$resolved_ch notifier failed with status $rc"
  return 0
}

decision_alert_prepare_channels() {
  local ch limit_logged=
  local -a configured=()
  DECISION_ALERT_CHANNELS=()
  while IFS= read -r ch; do
    [ -n "$ch" ] && configured+=("$ch")
  done < <(decision_alert_configured_channels)
  for ch in "${configured[@]}"; do
    [ "$ch" = off ] && return 1
  done
  for ch in "${configured[@]}"; do
    case "$ch" in auto|default) ch=$(decision_alert_platform_default) ;; esac
    case "$ch" in
      '') ;;
      osascript|herdr|command:*)
        if [ "${#DECISION_ALERT_CHANNELS[@]}" -lt "$DECISION_ALERT_MAX_WORKERS" ]; then
          DECISION_ALERT_CHANNELS+=("$ch")
        elif [ -z "$limit_logged" ]; then
          decision_alert_log "channel limit is $DECISION_ALERT_MAX_WORKERS; remaining directives ignored"
          limit_logged=1
        fi
        ;;
      *) decision_alert_log 'unrecognized channel directive ignored (redacted)' ;;
    esac
  done
  [ "${#DECISION_ALERT_CHANNELS[@]}" -gt 0 ]
}

decision_alert_add_identity() {  # <origin-id> <decision-key>
  local origin=$1 key=$2
  decision_alert_validate_slug origin-id "$origin" || return 2
  decision_alert_validate_slug decision-key "$key" || return 2
  DECISION_ALERT_ORIGINS+=("$origin")
  DECISION_ALERT_KEYS+=("$key")
}

decision_alert_dispatch() {
  local timeout override remaining identity_count channel_count batch_capacity total_jobs
  local job_index remaining_jobs remaining_batches batch_timeout batch_end
  local identity_index channel_index claim_state_value pid
  local -a claim_states=() pids=()
  [ "${#DECISION_ALERT_ORIGINS[@]}" -gt 0 ] || return 0
  decision_alert_prepare_channels || return 0
  [ -n "$DECISION_ALERT_DEADLINE" ] || decision_alert_begin_budget
  timeout=${FM_DECISION_ALERT_TIMEOUT_SECS:-$DECISION_ALERT_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in ''|*[!0-9]*|0) timeout=$DECISION_ALERT_TIMEOUT_SECS_DEFAULT ;; esac
  override=${FM_DECISION_ALERT_EXEC:-}
  identity_count=${#DECISION_ALERT_ORIGINS[@]}
  channel_count=${#DECISION_ALERT_CHANNELS[@]}
  batch_capacity=$((DECISION_ALERT_MAX_WORKERS / channel_count * channel_count))
  total_jobs=$((identity_count * channel_count))
  job_index=0
  while [ "$job_index" -lt "$total_jobs" ]; do
    remaining=$(decision_alert_remaining_budget) || break
    remaining_jobs=$((total_jobs - job_index))
    remaining_batches=$(((remaining_jobs + batch_capacity - 1) / batch_capacity))
    batch_timeout=$((remaining / remaining_batches))
    [ "$batch_timeout" -gt 0 ] || batch_timeout=1
    [ "$batch_timeout" -le "$timeout" ] || batch_timeout=$timeout
    batch_end=$((job_index + batch_capacity))
    [ "$batch_end" -le "$total_jobs" ] || batch_end=$total_jobs
    pids=()
    while [ "$job_index" -lt "$batch_end" ]; do
      identity_index=$((job_index / channel_count))
      channel_index=$((job_index % channel_count))
      claim_state_value=${claim_states[$identity_index]:-}
      if [ -z "$claim_state_value" ]; then
        if decision_alert_claim "${DECISION_ALERT_ORIGINS[$identity_index]}" \
          "${DECISION_ALERT_KEYS[$identity_index]}"; then
          claim_state_value=claimed
        else
          claim_state_value=skipped
        fi
        claim_states[identity_index]=$claim_state_value
      fi
      if [ "$claim_state_value" = claimed ]; then
        decision_alert_emit_channel "${DECISION_ALERT_CHANNELS[$channel_index]}" \
          "$override" "$batch_timeout" &
        pids+=("$!")
      fi
      job_index=$((job_index + 1))
    done
    if [ "${#pids[@]}" -gt 0 ]; then
      for pid in "${pids[@]}"; do
        wait "$pid" || true
      done
    fi
  done
  return 0
}

decision_alert_collect_status() {  # <status-file>
  local status_file=$1 task open key verb _note
  [ -f "$status_file" ] || return 0
  task=$(basename "$status_file")
  task=${task%.status}
  decision_alert_validate_slug task-id "$task" || return 2
  open=$(status_open_decisions "$status_file")
  while IFS=$'\t' read -r key verb _note; do
    [ -n "$key" ] || continue
    [ "$verb" = needs-decision ] || continue
    decision_alert_add_identity "$task" "$key" || true
  done <<EOF
$open
EOF
}

decision_alert_notify() {  # <origin-id> <decision-key>
  DECISION_ALERT_ORIGINS=()
  DECISION_ALERT_KEYS=()
  decision_alert_add_identity "$1" "$2" || return $?
  decision_alert_dispatch
}

decision_alert_status() {  # <status-file>
  DECISION_ALERT_ORIGINS=()
  DECISION_ALERT_KEYS=()
  decision_alert_collect_status "$1" || return $?
  decision_alert_dispatch
}

decision_alert_scan_state() {
  local status_file
  DECISION_ALERT_ORIGINS=()
  DECISION_ALERT_KEYS=()
  for status_file in "$STATE"/*.status; do
    [ -e "$status_file" ] || continue
    decision_alert_collect_status "$status_file" || true
  done
  decision_alert_dispatch
}

decision_alert_main() {
  local command=${1:-}
  case "$command" in
    decision|prompt)
      [ "$#" -eq 3 ] || { usage >&2; return 2; }
      decision_alert_begin_budget
      decision_alert_notify "$2" "$3"
      ;;
    status)
      [ "$#" -eq 2 ] || { usage >&2; return 2; }
      decision_alert_begin_budget
      decision_alert_status "$2"
      ;;
    scan-state)
      [ "$#" -eq 1 ] || { usage >&2; return 2; }
      decision_alert_begin_budget
      decision_alert_scan_state
      ;;
    -h|--help) usage ;;
    *) usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  : "${FM_DECISION_ALERT_EXEC:=discard}"
  export FM_DECISION_ALERT_EXEC
else
  decision_alert_main "$@"
fi
