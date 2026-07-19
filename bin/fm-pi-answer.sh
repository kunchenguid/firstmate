#!/usr/bin/env bash
# Guarded Firstmate answer publisher for a pending Pi supervised question.
# Usage: printf '%s\n' '{"answers":[...]}' | FM_HOME=<home> fm-pi-answer.sh <task-id> <call-id>
# The answer shape and lifecycle are owned by docs/pi-supervised-questions.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
# shellcheck source=bin/fm-pi-question-lib.sh
. "$SCRIPT_DIR/fm-pi-question-lib.sh"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ "$#" -eq 2 ] || fail "usage: fm-pi-answer.sh <task-id> <call-id> (answer JSON on stdin)" 2
[ -n "${FM_HOME:-}" ] || fail "FM_HOME must be explicit" 2
case "$FM_HOME" in /*) : ;; *) fail "FM_HOME must be absolute" 2 ;; esac
[ -d "$FM_HOME" ] || fail "FM_HOME is not a directory" 2
TASK_ID=$1
CALL_ID=$2
fm_pi_question_id_valid "$TASK_ID" || fail "invalid task ID" 2
fm_pi_question_id_valid "$CALL_ID" || fail "invalid call ID" 2
command -v jq >/dev/null 2>&1 || fail "jq is required"

STATE="$FM_HOME/state"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
fm_pi_question_task_is_pi "$STATE" "$TASK_ID" || fail "task is not owned by a Pi crew"
QUESTION_DIR="$STATE/questions/$TASK_ID"
[ -d "$QUESTION_DIR" ] && [ ! -L "$QUESTION_DIR" ] || fail "no pending Pi question for task $TASK_ID"
REQUEST="$QUESTION_DIR/$CALL_ID.request.json"
RESPONSE="$QUESTION_DIR/$CALL_ID.response.json"
OWNER="$QUESTION_DIR/$CALL_ID.owner.json"
RESOLUTION="$QUESTION_DIR/$CALL_ID.resolution.json"
[ -f "$REQUEST" ] && [ ! -L "$REQUEST" ] || fail "request $CALL_ID is absent"
[ -f "$OWNER" ] && [ ! -L "$OWNER" ] || fail "request $CALL_ID has no owner identity"
fm_pi_question_request_valid "$REQUEST" || fail "request $CALL_ID is malformed"
fm_pi_question_owner_valid "$OWNER" "$REQUEST" || fail "request $CALL_ID has a malformed owner identity"
[ "$(jq -r '.taskId' "$REQUEST")" = "$TASK_ID" ] || fail "request task ownership does not match"
[ "$(jq -r '.callId' "$REQUEST")" = "$CALL_ID" ] || fail "request call ID does not match"

umask 077
ANSWER_INPUT=$(mktemp "${TMPDIR:-/tmp}/fm-pi-answer.XXXXXXXXXX") || fail "cannot create answer buffer"
cleanup() {
  fm_pi_question_lock_release
  rm -f "$ANSWER_INPUT"
}
trap cleanup EXIT
cat > "$ANSWER_INPUT" || fail "cannot read answer JSON"

ANSWERED_AT=$(fm_pi_question_now_iso) || fail "cannot create answer timestamp"
RESPONSE_JSON=$(jq -ceS \
  --argjson version "$FM_PI_ASK_PROTOCOL_VERSION" \
  --arg taskId "$TASK_ID" \
  --arg callId "$CALL_ID" \
  --arg answeredAt "$ANSWERED_AT" \
  'if type == "object" and ((keys_unsorted - ["answers"]) | length == 0) and (.answers | type == "array")
   then {protocolVersion: $version, taskId: $taskId, callId: $callId, answeredAt: $answeredAt, answers: .answers}
   else error("invalid answer envelope") end' "$ANSWER_INPUT" 2>/dev/null) \
  || fail "answer must be one JSON object containing only answers"
VALIDATION_INPUT=$(mktemp "$QUESTION_DIR/.pi-answer.XXXXXXXXXX") || fail "cannot create validation buffer"
printf '%s\n' "$RESPONSE_JSON" > "$VALIDATION_INPUT"
chmod 0600 "$VALIDATION_INPUT"
fm_pi_question_response_valid "$VALIDATION_INPUT" "$REQUEST" || {
  rm -f "$VALIDATION_INPUT"
  fail "answer does not select exactly one listed label for each question in input order"
}
rm -f "$VALIDATION_INPUT"

fm_pi_question_lock_acquire "$QUESTION_DIR" "$CALL_ID" || fail "question state is busy"
[ ! -e "$RESOLUTION" ] || fail "request $CALL_ID is already resolved; stale answers are refused"
[ ! -e "$RESPONSE" ] || fail "request $CALL_ID already has an answer"
fm_pi_question_owner_process_alive "$OWNER" owner || fail "owning Pi process is no longer alive; stale answers are refused"
fm_pi_question_owner_process_alive "$OWNER" bridge || fail "question bridge is no longer alive; stale answers are refused"
DEADLINE=$(jq -r '.deadline' "$REQUEST")
DEADLINE_EPOCH=$(fm_pi_question_iso_epoch "$DEADLINE") || fail "request deadline is invalid"
[ "$(date +%s)" -lt "$DEADLINE_EPOCH" ] || fail "request deadline has expired; stale answers are refused"
fm_pi_question_atomic_write "$RESPONSE_JSON" "$RESPONSE" || fail "cannot publish answer"
fm_pi_question_lock_release
printf 'answered state/questions/%s/%s.response.json\n' "$TASK_ID" "$CALL_ID"
