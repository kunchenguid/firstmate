#!/usr/bin/env bash
# Publish one Pi supervised-question request and block until its matching answer.
# Usage: FM_HOME=<home> FM_TASK_ID=<task> FM_INTERACTION_MODE=supervised \
#          FM_ASK_BRIDGE=<absolute-this-script> fm-pi-ask-bridge.sh < request.json
# Stdout is reserved for the exact tool result: {"answers":[...]}.
# Errors are bounded and written to stderr with stable ASK_USER_* codes.
# The complete protocol and state paths are owned by docs/pi-supervised-questions.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ "$#" -eq 0 ] || { echo "error: fm-pi-ask-bridge.sh takes request JSON on stdin" >&2; exit 2; }
# shellcheck source=bin/fm-pi-question-lib.sh
. "$SCRIPT_DIR/fm-pi-question-lib.sh"

fail() {
  printf '%s: %s\n' "$1" "$2" >&2
  exit "${3:-1}"
}

[ "${FM_INTERACTION_MODE:-}" = supervised ] || fail ASK_USER_UNAVAILABLE "FM_INTERACTION_MODE must be supervised"
[ -n "${FM_HOME:-}" ] || fail ASK_USER_UNAVAILABLE "FM_HOME is required"
case "$FM_HOME" in /*) : ;; *) fail ASK_USER_UNAVAILABLE "FM_HOME must be absolute" ;; esac
[ -n "${FM_TASK_ID:-}" ] || fail ASK_USER_UNAVAILABLE "FM_TASK_ID is required"
case "${FM_ASK_BRIDGE:-}" in /*) : ;; *) fail ASK_USER_UNAVAILABLE "FM_ASK_BRIDGE must be absolute" ;; esac
[ -d "$FM_HOME" ] || fail ASK_USER_UNAVAILABLE "FM_HOME is not a directory"
fm_pi_question_id_valid "$FM_TASK_ID" || fail ASK_USER_INVALID_REQUEST "invalid task ID"

STATE="$FM_HOME/state"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail ASK_USER_UNAVAILABLE "state directory is unavailable"
fm_pi_question_task_is_pi "$STATE" "$FM_TASK_ID" || fail ASK_USER_UNAVAILABLE "task is not owned by a Pi crew"
command -v jq >/dev/null 2>&1 || fail ASK_USER_UNAVAILABLE "jq is required"

umask 077
REQUEST_INPUT=$(mktemp "${TMPDIR:-/tmp}/fm-pi-question.XXXXXXXXXX") || fail ASK_USER_BRIDGE_ERROR "cannot create request buffer"
cleanup() {
  fm_pi_question_lock_release
  rm -f "$REQUEST_INPUT"
}
trap cleanup EXIT
cat > "$REQUEST_INPUT" || fail ASK_USER_INVALID_REQUEST "cannot read request"
fm_pi_question_request_valid "$REQUEST_INPUT" || fail ASK_USER_INVALID_REQUEST "request does not match protocol v1"

TASK_ID=$(jq -r '.taskId' "$REQUEST_INPUT")
CALL_ID=$(jq -r '.callId' "$REQUEST_INPUT")
[ "$TASK_ID" = "$FM_TASK_ID" ] || fail ASK_USER_INVALID_REQUEST "request task ID does not match launch envelope"
fm_pi_question_id_valid "$CALL_ID" || fail ASK_USER_INVALID_REQUEST "invalid call ID"

CREATED_AT=$(jq -r '.createdAt' "$REQUEST_INPUT")
DEADLINE=$(jq -r '.deadline' "$REQUEST_INPUT")
CREATED_EPOCH=$(fm_pi_question_iso_epoch "$CREATED_AT") || fail ASK_USER_INVALID_REQUEST "createdAt is invalid"
DEADLINE_EPOCH=$(fm_pi_question_iso_epoch "$DEADLINE") || fail ASK_USER_INVALID_REQUEST "deadline is invalid"
NOW=$(date +%s)
MAX_WAIT=${FM_PI_ASK_MAX_WAIT_SECS:-86400}
case "$MAX_WAIT" in ''|*[!0-9]*) MAX_WAIT=86400 ;; esac
[ "$CREATED_EPOCH" -le $((NOW + 60)) ] || fail ASK_USER_INVALID_REQUEST "createdAt is in the future"
[ "$DEADLINE_EPOCH" -gt "$NOW" ] || fail ASK_USER_TIMEOUT "deadline has passed"
[ "$DEADLINE_EPOCH" -gt "$CREATED_EPOCH" ] || fail ASK_USER_INVALID_REQUEST "deadline must follow createdAt"
[ "$DEADLINE_EPOCH" -le $((NOW + MAX_WAIT)) ] || fail ASK_USER_INVALID_REQUEST "deadline exceeds the supervised wait limit"

QUESTION_DIR=$(fm_pi_question_prepare_directory "$STATE" "$TASK_ID") || fail ASK_USER_BRIDGE_ERROR "cannot prepare private question directory"
REQUEST="$QUESTION_DIR/$CALL_ID.request.json"
RESPONSE="$QUESTION_DIR/$CALL_ID.response.json"
OWNER="$QUESTION_DIR/$CALL_ID.owner.json"
RESOLUTION="$QUESTION_DIR/$CALL_ID.resolution.json"

fm_pi_question_lock_acquire "$QUESTION_DIR" "$CALL_ID" || fail ASK_USER_BRIDGE_ERROR "question state is busy"
if [ -e "$REQUEST" ] || [ -e "$RESPONSE" ] || [ -e "$OWNER" ] || [ -e "$RESOLUTION" ]; then
  fail ASK_USER_STALE_CALL "call ID has already been published; reissue with a new call ID"
fi

OWNER_START=$(fm_pi_question_process_start "$PPID") || fail ASK_USER_BRIDGE_ERROR "cannot identify owning Pi process"
BRIDGE_START=$(fm_pi_question_process_start "$$") || fail ASK_USER_BRIDGE_ERROR "cannot identify bridge process"
OWNER_JSON=$(jq -cnS \
  --argjson protocolVersion "$FM_PI_ASK_PROTOCOL_VERSION" \
  --arg taskId "$TASK_ID" \
  --arg callId "$CALL_ID" \
  --argjson ownerPid "$PPID" \
  --arg ownerStart "$OWNER_START" \
  --argjson bridgePid "$$" \
  --arg bridgeStart "$BRIDGE_START" \
  '{protocolVersion: $protocolVersion, taskId: $taskId, callId: $callId, ownerPid: $ownerPid, ownerStart: $ownerStart, bridgePid: $bridgePid, bridgeStart: $bridgeStart}') \
  || fail ASK_USER_BRIDGE_ERROR "cannot encode owner identity"
REQUEST_JSON=$(jq -cS . "$REQUEST_INPUT") || fail ASK_USER_INVALID_REQUEST "cannot canonicalize request"
fm_pi_question_atomic_write "$OWNER_JSON" "$OWNER" || fail ASK_USER_BRIDGE_ERROR "cannot publish owner identity"
fm_pi_question_atomic_write "$REQUEST_JSON" "$REQUEST" || fail ASK_USER_BRIDGE_ERROR "cannot publish request"
fm_pi_question_lock_release

fm_pi_question_append_status "$STATE" "$TASK_ID" \
  "needs-decision: Pi question request state/questions/$TASK_ID/$CALL_ID.request.json [key=ask-$CALL_ID]" \
  || fail ASK_USER_BRIDGE_ERROR "cannot publish decision status"

CANCELLED=0
trap 'CANCELLED=1' HUP INT TERM

resolve_failure() {
  local status=$1 detail=$2 code=$3 message=$4 resolution_json
  fm_pi_question_lock_acquire "$QUESTION_DIR" "$CALL_ID" || fail ASK_USER_BRIDGE_ERROR "question state is busy"
  if [ -f "$RESOLUTION" ]; then
    fm_pi_question_lock_release
    fail "$code" "$message"
  fi
  resolution_json=$(fm_pi_question_resolution_json "$TASK_ID" "$CALL_ID" "$status" "$detail") \
    || fail ASK_USER_BRIDGE_ERROR "cannot encode resolution"
  fm_pi_question_atomic_write "$resolution_json" "$RESOLUTION" \
    || fail ASK_USER_BRIDGE_ERROR "cannot publish resolution"
  fm_pi_question_lock_release
  fm_pi_question_append_status "$STATE" "$TASK_ID" \
    "resolved: Pi question $detail [key=ask-$CALL_ID]" || true
  fail "$code" "$message"
}

consume_response() {
  local result resolution_json
  fm_pi_question_lock_acquire "$QUESTION_DIR" "$CALL_ID" || fail ASK_USER_BRIDGE_ERROR "question state is busy"
  if [ -f "$RESOLUTION" ]; then
    fm_pi_question_lock_release
    return 1
  fi
  if ! fm_pi_question_response_valid "$RESPONSE" "$REQUEST"; then
    fm_pi_question_lock_release
    resolve_failure invalid-response "answer was invalid" ASK_USER_MALFORMED_RESPONSE "response does not match the pending request"
  fi
  resolution_json=$(fm_pi_question_resolution_json "$TASK_ID" "$CALL_ID" answered "answered") \
    || fail ASK_USER_BRIDGE_ERROR "cannot encode resolution"
  fm_pi_question_atomic_write "$resolution_json" "$RESOLUTION" \
    || fail ASK_USER_BRIDGE_ERROR "cannot publish resolution"
  result=$(jq -cS '{answers: .answers}' "$RESPONSE") || fail ASK_USER_BRIDGE_ERROR "cannot encode tool result"
  fm_pi_question_lock_release
  fm_pi_question_append_status "$STATE" "$TASK_ID" \
    "resolved: Pi question answered [key=ask-$CALL_ID]" \
    || fail ASK_USER_BRIDGE_ERROR "cannot publish resolution status"
  printf '%s\n' "$result"
  exit 0
}

fail_from_resolution() {
  local status
  status=$(jq -er '.status' "$RESOLUTION" 2>/dev/null) \
    || fail ASK_USER_BRIDGE_ERROR "terminal resolution is malformed"
  case "$status" in
    cancelled) fail ASK_USER_CANCELLED "question was cancelled" ;;
    timed-out) fail ASK_USER_TIMEOUT "question deadline expired" ;;
    abandoned) fail ASK_USER_ABANDONED "question owner or bridge exited" ;;
    invalid-request) fail ASK_USER_INVALID_REQUEST "request was invalidated during recovery" ;;
    invalid-response) fail ASK_USER_MALFORMED_RESPONSE "response was invalidated during recovery" ;;
    answered) fail ASK_USER_BRIDGE_ERROR "answered resolution exists without a consumable response" ;;
    *) fail ASK_USER_BRIDGE_ERROR "unknown terminal resolution" ;;
  esac
}

wait_for_change() {
  local seconds=$1 notifier_pid='' notifier_start timer_pid timer_start
  if command -v fswatch >/dev/null 2>&1; then
    fswatch -1 "$QUESTION_DIR" >/dev/null 2>&1 &
    notifier_pid=$!
  elif command -v inotifywait >/dev/null 2>&1; then
    inotifywait -q -e close_write,moved_to,create "$QUESTION_DIR" >/dev/null 2>&1 &
    notifier_pid=$!
  else
    sleep "$seconds"
    return
  fi
  notifier_start=$(fm_pi_question_process_start "$notifier_pid") || {
    kill "$notifier_pid" 2>/dev/null || true
    wait "$notifier_pid" 2>/dev/null || true
    sleep "$seconds"
    return
  }
  (
    sleep "$seconds"
    if fm_pi_question_process_matches "$notifier_pid" "$notifier_start"; then
      kill "$notifier_pid" 2>/dev/null || true
    fi
  ) &
  timer_pid=$!
  timer_start=$(fm_pi_question_process_start "$timer_pid" 2>/dev/null || true)
  wait "$notifier_pid" 2>/dev/null || true
  if fm_pi_question_process_matches "$notifier_pid" "$notifier_start"; then
    kill "$notifier_pid" 2>/dev/null || true
    wait "$notifier_pid" 2>/dev/null || true
  fi
  if [ -n "$timer_start" ] && fm_pi_question_process_matches "$timer_pid" "$timer_start"; then
    kill "$timer_pid" 2>/dev/null || true
  fi
  wait "$timer_pid" 2>/dev/null || true
}

POLL=${FM_PI_ASK_POLL_SECONDS:-1}
if ! jq -en --arg value "$POLL" '($value | tonumber) > 0' >/dev/null 2>&1; then
  POLL=1
fi
while :; do
  [ "$CANCELLED" -eq 0 ] || resolve_failure cancelled "was cancelled" ASK_USER_CANCELLED "question was cancelled"
  [ ! -f "$RESOLUTION" ] || fail_from_resolution
  if [ -f "$RESPONSE" ]; then
    consume_response
  fi
  if ! fm_pi_question_owner_process_alive "$OWNER" owner; then
    resolve_failure abandoned "was abandoned" ASK_USER_ABANDONED "owning Pi process exited"
  fi
  NOW=$(date +%s)
  [ "$NOW" -lt "$DEADLINE_EPOCH" ] || resolve_failure timed-out "timed out" ASK_USER_TIMEOUT "question deadline expired"
  wait_for_change "$POLL"
done
