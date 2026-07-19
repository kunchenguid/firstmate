#!/usr/bin/env bash
# Shared protocol, validation, locking, and atomic-file helpers for the
# Firstmate-owned Pi supervised-question bridge.
#
# The complete wire and state schema is owned by docs/pi-supervised-questions.md.
# Callers must validate task and call IDs before deriving paths from them.

FM_PI_ASK_PROTOCOL_VERSION=1
FM_PI_ASK_LOCK_ATTEMPTS=${FM_PI_ASK_LOCK_ATTEMPTS:-100}
FM_PI_ASK_LOCK_SLEEP=${FM_PI_ASK_LOCK_SLEEP:-0.05}
FM_PI_ASK_LOCK_DIR=
FM_PI_ASK_LOCK_PID=
FM_PI_ASK_LOCK_START=

fm_pi_question_id_valid() {
  local id=${1:-} LC_ALL=C
  case "$id" in
    ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

fm_pi_question_now_iso() {
  jq -nr 'now | floor | todateiso8601'
}

fm_pi_question_iso_epoch() {
  jq -enr --arg value "$1" '$value | fromdateiso8601'
}

fm_pi_question_process_start() {
  local pid=$1 value
  value=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_pi_question_process_matches() {
  local pid=$1 expected=$2 observed
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  observed=$(fm_pi_question_process_start "$pid") || return 1
  [ "$observed" = "$expected" ]
}

fm_pi_question_request_valid() {
  local request=$1
  jq -e --argjson version "$FM_PI_ASK_PROTOCOL_VERSION" '
    type == "object"
    and ((keys_unsorted - ["protocolVersion", "taskId", "callId", "createdAt", "deadline", "questions"]) | length == 0)
    and .protocolVersion == $version
    and (.taskId | type == "string" and length >= 1 and length <= 64 and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$"))
    and (.callId | type == "string" and length >= 1 and length <= 64 and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$"))
    and (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.deadline | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.questions | type == "array" and length >= 1 and length <= 4)
    and ([.questions[].id] | length == (unique | length))
    and all(.questions[];
      type == "object"
      and ((keys_unsorted - ["id", "header", "question", "options"]) | length == 0)
      and (.id | type == "string" and length >= 1 and length <= 64 and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$"))
      and (.header | type == "string" and utf8bytelength >= 1 and utf8bytelength <= 40)
      and (.question | type == "string" and utf8bytelength >= 1 and utf8bytelength <= 500)
      and (.options | type == "array" and length >= 2 and length <= 4)
      and ([.options[].label] | length == (unique | length))
      and all(.options[];
        type == "object"
        and ((keys_unsorted - ["label", "description"]) | length == 0)
        and (.label | type == "string" and utf8bytelength >= 1 and utf8bytelength <= 100)
        and (.description | type == "string" and utf8bytelength <= 500)
      )
    )
  ' "$request" >/dev/null 2>&1
}

fm_pi_question_response_valid() {
  local response=$1 request=$2 answered_at created_at deadline answered_epoch created_epoch deadline_epoch now
  jq -e --argjson version "$FM_PI_ASK_PROTOCOL_VERSION" --slurpfile request "$request" '
    . as $response
    | type == "object"
    and ((keys_unsorted - ["protocolVersion", "taskId", "callId", "answeredAt", "answers"]) | length == 0)
    and .protocolVersion == $version
    and .taskId == $request[0].taskId
    and .callId == $request[0].callId
    and (.answeredAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.answers | type == "array" and length == ($request[0].questions | length))
    and ([range(0; ($response.answers | length)) as $index
      | $response.answers[$index] as $answer
      | $request[0].questions[$index] as $question
      | ($answer | type == "object")
        and (($answer | keys_unsorted) - ["questionId", "selectedLabel"] | length == 0)
        and ($answer.questionId == $question.id)
        and ($answer.selectedLabel | type == "string")
        and any($question.options[]; .label == $answer.selectedLabel)
    ] | all)
  ' "$response" >/dev/null 2>&1 || return 1
  answered_at=$(jq -er '.answeredAt' "$response" 2>/dev/null) || return 1
  created_at=$(jq -er '.createdAt' "$request" 2>/dev/null) || return 1
  deadline=$(jq -er '.deadline' "$request" 2>/dev/null) || return 1
  answered_epoch=$(fm_pi_question_iso_epoch "$answered_at" 2>/dev/null) || return 1
  created_epoch=$(fm_pi_question_iso_epoch "$created_at" 2>/dev/null) || return 1
  deadline_epoch=$(fm_pi_question_iso_epoch "$deadline" 2>/dev/null) || return 1
  now=$(date +%s)
  [ "$answered_epoch" -ge "$created_epoch" ] \
    && [ "$answered_epoch" -le "$deadline_epoch" ] \
    && [ "$answered_epoch" -le $((now + 60)) ]
}

fm_pi_question_owner_valid() {
  local owner=$1 request=$2
  jq -e --argjson version "$FM_PI_ASK_PROTOCOL_VERSION" --slurpfile request "$request" '
    type == "object"
    and ((keys_unsorted - ["protocolVersion", "taskId", "callId", "ownerPid", "ownerStart", "bridgePid", "bridgeStart"]) | length == 0)
    and .protocolVersion == $version
    and .taskId == $request[0].taskId
    and .callId == $request[0].callId
    and (.ownerPid | type == "number" and floor == . and . > 1)
    and (.bridgePid | type == "number" and floor == . and . > 1)
    and (.ownerStart | type == "string" and length > 0 and length <= 128)
    and (.bridgeStart | type == "string" and length > 0 and length <= 128)
  ' "$owner" >/dev/null 2>&1
}

fm_pi_question_resolution_valid() {
  local resolution=$1 task_id=$2 call_id=$3 resolved_at resolved_epoch now
  jq -e \
    --argjson version "$FM_PI_ASK_PROTOCOL_VERSION" \
    --arg taskId "$task_id" \
    --arg callId "$call_id" '
      type == "object"
      and ((keys_unsorted - ["protocolVersion", "taskId", "callId", "status", "resolvedAt", "detail"]) | length == 0)
      and .protocolVersion == $version
      and .taskId == $taskId
      and .callId == $callId
      and (.status == "answered" or .status == "cancelled" or .status == "timed-out" or .status == "abandoned" or .status == "invalid-request" or .status == "invalid-response")
      and (.resolvedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (.detail | type == "string" and utf8bytelength >= 1 and utf8bytelength <= 120 and ((contains("\n") or contains("\r")) | not))
    ' "$resolution" >/dev/null 2>&1 || return 1
  resolved_at=$(jq -er '.resolvedAt' "$resolution" 2>/dev/null) || return 1
  resolved_epoch=$(fm_pi_question_iso_epoch "$resolved_at" 2>/dev/null) || return 1
  now=$(date +%s)
  [ "$resolved_epoch" -le $((now + 60)) ]
}

fm_pi_question_owner_process_alive() {
  local owner=$1 role=$2 pid start
  case "$role" in
    owner)
      pid=$(jq -er '.ownerPid' "$owner" 2>/dev/null) || return 1
      start=$(jq -er '.ownerStart' "$owner" 2>/dev/null) || return 1
      ;;
    bridge)
      pid=$(jq -er '.bridgePid' "$owner" 2>/dev/null) || return 1
      start=$(jq -er '.bridgeStart' "$owner" 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  fm_pi_question_process_matches "$pid" "$start"
}

fm_pi_question_atomic_write() {
  local content=$1 destination=$2 directory tmp
  directory=${destination%/*}
  tmp=$(mktemp "$directory/.pi-question.XXXXXXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_pi_question_lock_release() {
  [ -n "$FM_PI_ASK_LOCK_DIR" ] || return 0
  if [ -f "$FM_PI_ASK_LOCK_DIR" ] && [ ! -L "$FM_PI_ASK_LOCK_DIR" ] \
    && [ "$(sed -n '1p' "$FM_PI_ASK_LOCK_DIR" 2>/dev/null || true)" = "$FM_PI_ASK_LOCK_PID" ] \
    && [ "$(sed -n '2p' "$FM_PI_ASK_LOCK_DIR" 2>/dev/null || true)" = "$FM_PI_ASK_LOCK_START" ]; then
    rm -f "$FM_PI_ASK_LOCK_DIR"
  fi
  FM_PI_ASK_LOCK_DIR=
  FM_PI_ASK_LOCK_PID=
  FM_PI_ASK_LOCK_START=
}

fm_pi_question_lock_acquire() {
  local directory=$1 call_id=$2 lock attempt=0 pid start lock_pid lock_start candidate
  fm_pi_question_id_valid "$call_id" || return 1
  lock="$directory/$call_id.lock"
  while [ "$attempt" -lt "$FM_PI_ASK_LOCK_ATTEMPTS" ]; do
    pid=$$
    start=$(fm_pi_question_process_start "$pid") || return 1
    candidate=$(mktemp "$directory/.pi-lock.XXXXXXXXXX") || return 1
    if ! printf '%s\n%s\n' "$pid" "$start" > "$candidate" || ! chmod 0600 "$candidate"; then
      rm -f "$candidate"
      return 1
    fi
    if ln "$candidate" "$lock" 2>/dev/null; then
      rm -f "$candidate"
      FM_PI_ASK_LOCK_DIR=$lock
      FM_PI_ASK_LOCK_PID=$pid
      FM_PI_ASK_LOCK_START=$start
      return 0
    fi
    rm -f "$candidate"
    if [ -f "$lock" ] && [ ! -L "$lock" ]; then
      lock_pid=$(sed -n '1p' "$lock" 2>/dev/null || true)
      lock_start=$(sed -n '2p' "$lock" 2>/dev/null || true)
      if ! fm_pi_question_process_matches "$lock_pid" "$lock_start"; then
        rm -f "$lock"
        continue
      fi
    fi
    sleep "$FM_PI_ASK_LOCK_SLEEP"
    attempt=$((attempt + 1))
  done
  return 1
}

fm_pi_question_resolution_json() {
  local task_id=$1 call_id=$2 status=$3 detail=$4 resolved_at
  resolved_at=$(fm_pi_question_now_iso) || return 1
  jq -cnS \
    --argjson protocolVersion "$FM_PI_ASK_PROTOCOL_VERSION" \
    --arg taskId "$task_id" \
    --arg callId "$call_id" \
    --arg status "$status" \
    --arg resolvedAt "$resolved_at" \
    --arg detail "$detail" \
    '{protocolVersion: $protocolVersion, taskId: $taskId, callId: $callId, status: $status, resolvedAt: $resolvedAt, detail: $detail}'
}

fm_pi_question_append_status() {
  local state=$1 task_id=$2 line=$3 status_file
  fm_pi_question_id_valid "$task_id" || return 1
  status_file="$state/$task_id.status"
  if [ -e "$status_file" ] && { [ ! -f "$status_file" ] || [ -L "$status_file" ]; }; then
    return 1
  fi
  printf '%s\n' "$line" >> "$status_file"
}

fm_pi_question_task_is_pi() {
  local state=$1 task_id=$2 meta harness
  fm_pi_question_id_valid "$task_id" || return 1
  meta="$state/$task_id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  harness=$(sed -n 's/^harness=//p' "$meta" | tail -1)
  [ "$harness" = pi ]
}

fm_pi_question_prepare_directory() {
  local state=$1 task_id=$2 root directory
  fm_pi_question_id_valid "$task_id" || return 1
  root="$state/questions"
  directory="$root/$task_id"
  [ ! -L "$root" ] && [ ! -L "$directory" ] || return 1
  mkdir -p "$directory" || return 1
  chmod 0700 "$root" "$directory" || return 1
  printf '%s\n' "$directory"
}
