#!/usr/bin/env bash
# Reconcile pending Pi supervised questions after process death or deadline expiry.
# Usage: FM_HOME=<home> fm-pi-question-recover.sh --all
#        FM_HOME=<home> fm-pi-question-recover.sh <task-id>
#        FM_HOME=<home> fm-pi-question-recover.sh --cancel <task-id>
# Recovery is idempotent and never answers a question.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
# shellcheck source=bin/fm-pi-question-lib.sh
. "$SCRIPT_DIR/fm-pi-question-lib.sh"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ -n "${FM_HOME:-}" ] || fail "FM_HOME must be explicit" 2
case "$FM_HOME" in /*) : ;; *) fail "FM_HOME must be absolute" 2 ;; esac
[ -d "$FM_HOME" ] || fail "FM_HOME is not a directory" 2
STATE="$FM_HOME/state"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"

MODE=${1:---all}
TASK_FILTER=
DETAIL=
case "$MODE" in
  --all)
    [ "$#" -eq 1 ] || fail "usage: fm-pi-question-recover.sh --all" 2
    ;;
  --cancel)
    [ "$#" -eq 2 ] || fail "usage: fm-pi-question-recover.sh --cancel <task-id>" 2
    TASK_FILTER=$2
    DETAIL="was cancelled"
    fm_pi_question_id_valid "$TASK_FILTER" || fail "invalid task ID" 2
    ;;
  *)
    [ "$#" -eq 1 ] || fail "usage: fm-pi-question-recover.sh <task-id>" 2
    TASK_FILTER=$MODE
    fm_pi_question_id_valid "$TASK_FILTER" || fail "invalid task ID" 2
    MODE=--task
    ;;
esac

ROOT="$STATE/questions"
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || exit 0
if [ -n "$TASK_FILTER" ] && [ ! -d "$ROOT/$TASK_FILTER" ]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || fail "jq is required"

resolve_request() {
  local task_id=$1 call_id=$2 status=$3 detail=$4 directory resolution resolution_json
  directory="$STATE/questions/$task_id"
  resolution="$directory/$call_id.resolution.json"
  fm_pi_question_lock_acquire "$directory" "$call_id" || return 1
  if [ -e "$resolution" ]; then
    fm_pi_question_lock_release
    return 0
  fi
  resolution_json=$(fm_pi_question_resolution_json "$task_id" "$call_id" "$status" "$detail") || return 1
  fm_pi_question_atomic_write "$resolution_json" "$resolution" || return 1
  fm_pi_question_lock_release
  if [ -f "$STATE/$task_id.meta" ]; then
    fm_pi_question_append_status "$STATE" "$task_id" \
      "resolved: Pi question $detail [key=ask-$call_id]" || return 1
  fi
}

ensure_resolution_status() {
  local task_id=$1 call_id=$2 resolution=$3 status_file detail suffix
  [ -f "$resolution" ] && [ ! -L "$resolution" ] || return 1
  fm_pi_question_resolution_valid "$resolution" "$task_id" "$call_id" || return 1
  status_file="$STATE/$task_id.status"
  suffix="[key=ask-$call_id]"
  if [ -f "$status_file" ] && awk -v suffix="$suffix" 'index($0, "resolved:") == 1 && index($0, suffix) > 0 { found=1 } END { exit !found }' "$status_file"; then
    return 0
  fi
  [ -f "$STATE/$task_id.meta" ] || return 0
  detail=$(jq -er '.detail' "$resolution") || return 1
  fm_pi_question_append_status "$STATE" "$task_id" \
    "resolved: Pi question $detail [key=ask-$call_id]"
}

recover_task() {
  local directory=$1 task_id request call_id owner resolution response deadline deadline_epoch now status detail
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 0
  task_id=${directory##*/}
  fm_pi_question_id_valid "$task_id" || return 0
  for request in "$directory"/*.request.json; do
    [ -f "$request" ] && [ ! -L "$request" ] || continue
    call_id=${request##*/}
    call_id=${call_id%.request.json}
    fm_pi_question_id_valid "$call_id" || continue
    owner="$directory/$call_id.owner.json"
    resolution="$directory/$call_id.resolution.json"
    response="$directory/$call_id.response.json"
    if [ -e "$resolution" ]; then
      ensure_resolution_status "$task_id" "$call_id" "$resolution" \
        || fail "cannot validate terminal Pi question $task_id/$call_id"
      continue
    fi
    status=
    detail=
    if [ "$MODE" = --cancel ]; then
      status=cancelled
      detail=$DETAIL
    elif ! fm_pi_question_request_valid "$request"; then
      status=invalid-request
      detail="request was invalid"
    elif [ ! -f "$owner" ] || [ -L "$owner" ] || ! fm_pi_question_owner_valid "$owner" "$request"; then
      status=abandoned
      detail="was abandoned"
    elif ! fm_pi_question_owner_process_alive "$owner" owner || ! fm_pi_question_owner_process_alive "$owner" bridge; then
      status=abandoned
      detail="was abandoned"
    elif [ -f "$response" ] && ! fm_pi_question_response_valid "$response" "$request"; then
      status=invalid-response
      detail="answer was invalid"
    else
      deadline=$(jq -r '.deadline' "$request")
      deadline_epoch=$(fm_pi_question_iso_epoch "$deadline" 2>/dev/null || printf '0')
      now=$(date +%s)
      if [ "$deadline_epoch" -le "$now" ]; then
        status=timed-out
        detail="timed out"
      fi
    fi
    [ -n "$status" ] || continue
    resolve_request "$task_id" "$call_id" "$status" "$detail" \
      || fail "cannot reconcile Pi question $task_id/$call_id"
  done
}

trap fm_pi_question_lock_release EXIT
if [ -n "$TASK_FILTER" ]; then
  recover_task "$ROOT/$TASK_FILTER"
else
  for directory in "$ROOT"/*; do
    recover_task "$directory"
  done
fi
