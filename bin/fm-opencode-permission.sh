#!/usr/bin/env bash
# Bridge one real OpenCode v2 permission request to the captain's existing
# decision path, and apply the captain's answer to exactly that request.
#
# The installed OpenCode 2 server exposes the ask as a pending request record
# (`GET /api/session/<sessionID>/permission/<requestID>`) and accepts the
# answer at `POST /api/session/<sessionID>/permission/<requestID>/reply` with
# the body `{"decision":"once"|"always"|"reject"}`. The v1-era typings shipped
# in the same install document `{reply, message}` and a `/permissions/`
# plural route; both are rejected by the running server, so nothing here reads
# those typings. The three decisions below are the installed server's own enum.
#
# Two subcommands, both identity-checked and idempotent:
#
#   ask <task-id> <session-id> <request-id>
#       Verify the request the server currently reports, record it durably
#       under state/<task-id>.opencode-permission/<request-id>.json, and push
#       the captain decision through bin/fm-discord-notify.sh with the
#       `perm-ask` trigger and a `perm-<request-id>` key. That key makes the
#       push single-fire: the notifier derives its record path and Discord
#       nonce from (trigger, task, key), so a repeated ask re-uses the same
#       message instead of sending a second one. Prints the key on success.
#
#   decide <task-id> <request-id> <once|always|reject>
#       Apply the captain's answer. Requires, in order: the record exists and
#       names this exact task; its state is `pending`; the task's current
#       busy generation still equals the one captured at ask time; the live
#       server still reports that request as pending with the same id and
#       session. The record is then marked `consumed` BEFORE the POST, so a
#       concurrent or replayed call finds a non-pending record and refuses
#       without granting. A consumed record whose POST failed stays
#       `consumed` with the error: the captain's answer is spent and only the
#       captain can grant a fresh one.
#
#   settle <task-id> <request-id> <once|always|reject>
#       Record a decision the worker applied itself (or the TUI answered), so
#       the audit trail closes on a server-confirmed outcome rather than
#       leaving the record pending forever. Never POSTs.
#
# Everything refuses rather than guessing. A missing, unreadable, mismatched,
# already-decided, stale-generation, or no-longer-pending request yields a
# nonzero exit and no API write. Teardown removes the whole record directory
# with the task's other state; a request that is never answered simply expires
# on the server, which is fail-closed by construction.
#
# No secrets, no second notification path, and no second approval ledger: the
# durable record here is the audit trail for THIS surface only, and the
# captain decision travels the existing Discord decision path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

RECORD_DIR_NAME="opencode-permission"
RECORD_SCHEMA="fm-opencode-permission-request.v1"
TRIGGER="perm-ask"

# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=/dev/null
# The wake library is also the repo's one portable lock implementation, and
# decide needs it: the record transition from pending to consumed has to be a
# single-writer critical section, or two concurrent decides could both read
# pending and both post. Sourcing it is a no-op when it is already loaded.
if ! command -v fm_lock_acquire_wait >/dev/null 2>&1; then
  . "$SCRIPT_DIR/fm-wake-lib.sh"
fi

fail() {
  printf 'fm-opencode-permission: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  case "$2" in
    ''|.*|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
}

record_dir() {  # <task-id>
  printf '%s/%s.%s' "$STATE" "$1" "$RECORD_DIR_NAME"
}

record_path() {  # <task-id> <request-id>
  printf '%s/%s.json' "$(record_dir "$1")" "$2"
}

opencode_bin() {
  local bin
  bin=$(command -v opencode) || fail "opencode executable not found on PATH"
  printf '%s' "$bin"
}

# Fetch one permission request and print the response body.
# A non-2xx response is an empty result, not a crash: the request has expired
# or never existed, and the caller decides what an absent request means.
permission_get() {  # <session-id> <request-id>
  "$(opencode_bin)" api GET "/api/session/$1/permission/$2" 2>/dev/null || true
}

# Read one JSON field with jq, printing nothing when absent or unparsable.
json_field() {  # <json> <field>
  printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // empty' 2>/dev/null || true
}

# Compact one-line JSON for a field, so a caller can render a list with its
# element boundaries intact. A delimiter-joined or space-joined rendering cannot
# do that: a path may contain spaces, commas, or newlines, so any delimiter the
# renderer picks can appear inside a value and silently misstate the scope.
json_compact() {  # <json> <field>
  printf '%s' "$1" | jq -c --arg f "$2" '(.[$f] // [])' 2>/dev/null || printf '[]'
}

command_ask() {
  [ "$#" -eq 3 ] || fail "usage: fm-opencode-permission.sh ask <task-id> <session-id> <request-id>"
  local task_id=$1 session_id=$2 request_id=$3 body live_id live_session action resources save tmp
  validate_slug task-id "$task_id"
  validate_slug session-id "$session_id"
  validate_slug request-id "$request_id"
  command -v jq >/dev/null 2>&1 || fail "missing jq"

  # The record is written only from what the SERVER reports about this exact
  # request, never from a caller's claim about it. A request the server does
  # not confirm is never pushed to the captain and never becomes decidable.
  body=$(permission_get "$session_id" "$request_id")
  [ -n "$body" ] || fail "refusing: the server reports no permission request $request_id in session $session_id"
  live_id=$(json_field "$body" id)
  live_session=$(json_field "$body" sessionID)
  [ "$live_id" = "$request_id" ] \
    || fail "refusing: server returned request id '$live_id' for requested id '$request_id'"
  [ "$live_session" = "$session_id" ] \
    || fail "refusing: server returned session id '$live_session' for requested session '$session_id'"
  action=$(json_field "$body" action)
  [ -n "$action" ] || fail "refusing: request $request_id carries no action"
  resources=$(json_compact "$body" resources)
  save=$(json_compact "$body" save)
  [ "$resources" != "[]" ] || fail "refusing: request $request_id names no resource"

  local dir gen
  dir=$(record_dir "$task_id")
  # A record that already exists is the same request seen again. Do not
  # overwrite it: the captured generation and options are the identity a
  # decision is checked against, and the notifier already made the push
  # single-fire for this key.
  if [ -e "$(record_path "$task_id" "$request_id")" ]; then
    # A push that failed once must be retried here, or the captain never sees
    # the decision and the worker stays blocked. The push is idempotent per
    # (trigger, task, key) - the notifier derives its record path and Discord
    # nonce from those, re-sends a prior failed record, and the poll's offered
    # marker refuses a duplicate reply - so re-pushing is safe. The captured
    # record is left untouched: its generation and lists are the identity a
    # later decision is checked against, and come from that first server read.
    push_captain_decision "$task_id" "$request_id" "$action" "$resources" "$save"
    printf 'perm-%s\n' "$request_id"
    return 0
  fi
  mkdir -p "$dir" || fail "cannot create $dir"
  chmod 700 "$dir" || fail "cannot secure $dir"
  # Fail closed when the task's generation cannot be read: a decide with no
  # generation to compare against could not detect a relaunched task.
  gen=$(fm_busy_current_gen "$STATE" "$task_id") \
    || fail "refusing: task $task_id has no current busy generation, so a later answer could not be proven to belong to this run"

  tmp=$(mktemp "$dir/.ask.XXXXXX") || fail "cannot stage the request record"
  # The resource and save lists go in as JSON arrays built from the server's own
  # fields, never re-joined and re-split on a delimiter: a path may legally
  # contain a comma, and a delimiter round trip would silently alter the scope
  # the captain is being shown.
  if ! jq -n \
    --arg schema "$RECORD_SCHEMA" \
    --arg task "$task_id" \
    --arg session "$session_id" \
    --arg request "$request_id" \
    --arg gen "$gen" \
    --arg at "$(date +%s)" \
    --argjson body "$body" \
    '{schema:$schema, task_id:$task, session_id:$session, request_id:$request,
      action:$body.action, resources:($body.resources // []), save:($body.save // []),
      generation:$gen, state:"pending", asked_at:($at|tonumber)}' \
    > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "cannot render the request record"
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; fail "cannot secure the staged request record"; }
  mv "$tmp" "$(record_path "$task_id" "$request_id")" \
    || { rm -f "$tmp"; fail "cannot publish the request record"; }

  push_captain_decision "$task_id" "$request_id" "$action" "$resources" "$save"
  printf 'perm-%s\n' "$request_id"
}

# The captain-facing question carries what the ask is, every resource it
# touches, everything an `always` answer would remember, and this surface's
# recommendation, so the reply is answerable from the message alone. Both lists
# arrive as compact JSON and are rendered whole: a request can name several
# resources, and approving it grants all of them, so showing only the first
# would have the captain approve scope he was never shown.
push_captain_decision() {  # <task-id> <request-id> <action> <resources-json> <save-json>
  local task_id=$1 request_id=$2 action=$3 resources=$4 save=$5
  local summary saved_note
  if [ "$save" != "[]" ]; then
    saved_note="Choosing 'remember this' would save these paths: $save"
  else
    saved_note="Nothing would be remembered: this ask has no save pattern."
  fi
  summary=$(printf 'OpenCode worker needs permission: action=%s resources=%s | %s | Recommendation: approve once and keep the saved scope unchanged; approve with remember only when the same path will be needed again this run.' \
    "$action" "$resources" "$saved_note")
  [ "${#summary}" -le 1800 ] || summary="${summary:0:1800}…"
  "$SCRIPT_DIR/fm-discord-notify.sh" "$TRIGGER" "$task_id" "perm-$request_id" \
    "$summary" \
    "Approve once|Approve once and remember this|Reject the request" "Approve once" >/dev/null \
    || printf 'actionable: the permission request was recorded but the captain decision push failed\n' >&2
}

# Load the record, or fail. Sets RECORD_BODY and RECORD_PATH.
load_record() {  # <task-id> <request-id>
  RECORD_PATH=$(record_path "$1" "$2")
  [ -f "$RECORD_PATH" ] && [ ! -L "$RECORD_PATH" ] \
    || fail "refusing: no permission request record at $RECORD_PATH"
  RECORD_BODY=$(cat "$RECORD_PATH" 2>/dev/null) \
    || fail "refusing: the permission request record at $RECORD_PATH is unreadable"
  [ "$(json_field "$RECORD_BODY" schema)" = "$RECORD_SCHEMA" ] \
    || fail "refusing: $RECORD_PATH is not a $RECORD_SCHEMA record"
  [ "$(json_field "$RECORD_BODY" task_id)" = "$1" ] \
    || fail "refusing: $RECORD_PATH belongs to task $(json_field "$RECORD_BODY" task_id), not $1"
  [ "$(json_field "$RECORD_BODY" request_id)" = "$2" ] \
    || fail "refusing: $RECORD_PATH records request $(json_field "$RECORD_BODY" request_id), not $2"
}

# Refuse anything already decided. Runs BEFORE the live read so a replay never
# reaches the server at all.
require_pending() {  # <record-body>
  local state
  state=$(json_field "$1" state)
  case "$state" in
    pending) ;;
    '') fail "refusing: the permission request record has no state" ;;
    *) fail "refusing: the permission request is already $state, so no second answer can apply" ;;
  esac
}

# Refuse when the task has moved on since the ask. A relaunched task is a
# different run: its generation differs, so the captain's answer to the earlier
# run's request is not an answer to anything this run can grant.
require_current_generation() {  # <task-id> <record-body>
  local recorded current
  recorded=$(json_field "$2" generation)
  [ -n "$recorded" ] || fail "refusing: the permission request record carries no task generation"
  current=$(fm_busy_current_gen "$STATE" "$1") \
    || fail "refusing: task $1 has no current busy generation, so this answer cannot be proven to belong to a live run"
  [ "$current" = "$recorded" ] \
    || fail "refusing: task $1 has moved to generation $current since this request was asked at $recorded"
}

# Refuse when the server no longer reports the request pending. This is the
# check that makes an expired, already-answered, or unknown request fail
# closed instead of posting a reply to a request that is not there.
require_pending_on_server() {  # <session-id> <request-id> <record-body>
  local body live_id live_session
  body=$(permission_get "$1" "$2")
  [ -n "$body" ] \
    || fail "refusing: the server no longer reports request $2 pending; it was answered, rejected, or expired"
  live_id=$(json_field "$body" id)
  live_session=$(json_field "$body" sessionID)
  [ "$live_id" = "$2" ] \
    || fail "refusing: the server returned request id '$live_id' where $2 was expected"
  [ "$live_session" = "$1" ] \
    || fail "refusing: the server returned session id '$live_session' where $1 was expected"
  local recorded_action
  recorded_action=$(json_field "$3" action)
  [ -z "$recorded_action" ] || [ "$(json_field "$body" action)" = "$recorded_action" ] \
    || fail "refusing: the server now reports action '$(json_field "$body" action)' for request $2, not the recorded '$recorded_action'"
}

write_state() {  # <record-body> <new-state> [decision] [error]
  local body=$1 state=$2 decision=${3:-} error=${4:-} tmp
  tmp=$(mktemp "$(dirname "$RECORD_PATH")/.settle.XXXXXX") || fail "cannot stage the record update"
  if ! jq -n --argjson base "$body" --arg state "$state" --arg decision "$decision" \
      --arg error "$error" --arg at "$(date +%s)" \
      '$base + {state:$state, decided_at:($at|tonumber)}
       + (if $decision == "" then {} else {decision:$decision} end)
       + (if $error == "" then {} else {apply_error:$error} end)' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "cannot render the record update"
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; fail "cannot secure the staged record update"; }
  mv "$tmp" "$RECORD_PATH" || { rm -f "$tmp"; fail "cannot publish the record update"; }
}

# Mark the record consumed BEFORE the API write. This is the commit point: any
# second caller, in this process or another, now refuses on the state check and
# cannot grant twice even if the first POST is still in flight.
consume() {  # <record-body> <decision>
  local body=$1 decision=$2 tmp
  tmp=$(mktemp "$(dirname "$RECORD_PATH")/.consume.XXXXXX") || fail "cannot stage the record transition"
  if ! jq -n --argjson base "$body" --arg decision "$decision" --arg at "$(date +%s)" \
      '$base + {state:"consumed", decision:$decision, consumed_at:($at|tonumber)}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "cannot render the consumed record"
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; fail "cannot secure the staged consumed record"; }
  mv "$tmp" "$RECORD_PATH" || { rm -f "$tmp"; fail "cannot publish the consumed record"; }
}

command_decide() {
  [ "$#" -eq 3 ] || fail "usage: fm-opencode-permission.sh decide <task-id> <request-id> <once|always|reject>"
  local task_id=$1 request_id=$2 decision=$3 session_id body response tmp lock
  validate_slug task-id "$task_id"
  validate_slug request-id "$request_id"
  case "$decision" in
    once|always|reject) ;;
    *) fail "refusing: '$decision' is not one of once, always, reject; no grant was made" ;;
  esac

  # Refuse an unknown request before taking any lock, so a task with no records
  # at all fails fast instead of waiting on a lock.
  load_record "$task_id" "$request_id"

  # The whole read-check-consume sequence is one critical section per request.
  # Without it two decides arriving together both read `pending` and both post:
  # the record state alone cannot prevent that, because the check and the
  # transition are separate operations. The lock is what makes "applied once"
  # true rather than merely intended.
  #
  # The lock lives directly in state/, never inside the per-task record
  # directory: a lock whose parent directory does not exist yet cannot be
  # created by the lock primitive, and waiting on one is an unbounded spin
  # rather than a refusal. state/ is this home's own durable root, so its
  # parent always exists, and both path components are validated slugs.
  lock="$STATE/.opencode-permission-$task_id-$request_id.lock"
  fm_lock_acquire_wait "$lock" || fail "refusing: cannot take the decision lock for $request_id"

  # Re-read under the lock: the read above was only a fast refusal, and this
  # one is the authoritative state the decision is based on.
  load_record "$task_id" "$request_id"
  body=$RECORD_BODY
  session_id=$(json_field "$body" session_id)
  validate_slug session-id "$session_id"
  require_pending "$body"
  require_current_generation "$task_id" "$body"
  require_pending_on_server "$session_id" "$request_id" "$body"

  consume "$body" "$decision"

  if ! response=$("$(opencode_bin)" api POST \
    "/api/session/$session_id/permission/$request_id/reply" \
    -d "$(jq -nc --arg decision "$decision" '{decision:$decision}')" 2>&1); then
    write_state "$body" "consumed" "$decision" "$response"
    fm_lock_release "$lock"
    fail "the captain's answer was recorded as consumed but the server refused it; no access was granted: $response"
  fi
  write_state "$body" "replied" "$decision"
  fm_lock_release "$lock"
  printf 'applied %s to %s\n' "$decision" "$request_id"
}

command_settle() {
  [ "$#" -eq 3 ] || fail "usage: fm-opencode-permission.sh settle <task-id> <request-id> <once|always|reject>"
  local task_id=$1 request_id=$2 decision=$3 body
  validate_slug task-id "$task_id"
  validate_slug request-id "$request_id"
  case "$decision" in
    once|always|reject) ;;
    *) fail "refusing: '$decision' is not one of once, always, reject" ;;
  esac
  load_record "$task_id" "$request_id"
  body=$RECORD_BODY
  case "$(json_field "$body" state)" in
    replied) printf 'already settled %s\n' "$request_id"; return 0 ;;
  esac
  write_state "$body" "replied" "$decision"
  printf 'settled %s as %s\n' "$request_id" "$decision"
}

case "${1:-}" in
  ask) shift; command_ask "$@" ;;
  decide) shift; command_decide "$@" ;;
  settle) shift; command_settle "$@" ;;
  -h|--help|"")
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    ;;
  *) fail "unknown subcommand: $1" ;;
esac
