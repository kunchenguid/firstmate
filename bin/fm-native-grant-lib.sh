#!/usr/bin/env bash
# fm-native-grant-lib.sh - strict validation of a native one-use resume grant
# presented to the launch owner's granted recovery path
# (bin/fm-spawn.sh --relaunch --native-grant <file>).
#
# Sourced, never executed. Callers must already hold the task's spawn and
# metadata locks, because the spend ledger below is serialized only by them.
#
# A native resume grant is the record a host restart writes for each stopped
# crew so its next launch may continue that crew's own native conversation.
# Its producer and its consumer (the slot dispatcher, which deletes the file
# when a launch reaches it) live outside this repository. This library does
# not consume the file; it only decides whether the grant licenses the one
# thing granted recovery may skip, the new-work dispatchability gate.
#
# Grant contract (all of it required, nothing else accepted):
#   - The file is a regular non-symlink file of at most 4096 bytes named
#     <task-id>.json.
#   - Its body is one JSON object with exactly the keys task, pane, agent,
#     session and written, no key repeated, every value a scalar.
#   - task equals the task id, agent equals the task record's harness, and
#     pane equals the task record's herdr_pane_id, all as exact strings.
#   - session is a lowercase native conversation UUID.
#   - written is an integer Unix time no later than now and no older than
#     43200 seconds (the producer's window).
#   - The grant's byte fingerprint is not already recorded in the task's
#     spend ledger, state/<id>.native-grant-spent. One grant licenses one
#     recovery attempt, whether or not that attempt then launches.
# Any other shape - a second mate's owner_home/secondmate_home grant included -
# is refused, so an unrecognized grant can never widen what it bypasses.
#
# Functions:
#   fm_native_grant_check <file> <task-id> <harness> <pane> <ledger>
#     0 when the grant satisfies the contract; otherwise 1 with
#     FM_NATIVE_GRANT_ERROR naming the first failed rule. On success it sets
#     FM_NATIVE_GRANT_FINGERPRINT and FM_NATIVE_GRANT_SESSION.
#   fm_native_grant_spend <ledger>
#     Records FM_NATIVE_GRANT_FINGERPRINT in the ledger. 1 with
#     FM_NATIVE_GRANT_ERROR when it cannot be recorded, in which case the
#     caller must refuse rather than launch on an unrecorded grant.

FM_NATIVE_GRANT_MAX_BYTES=4096
FM_NATIVE_GRANT_MAX_AGE=43200

fm_native_grant_fingerprint() {  # reads the grant bytes on stdin
  local sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256) || return 1
  else
    return 1
  fi
  sum=${sum%% *}
  case "$sum" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#sum}" -eq 64 ] || return 1
  printf '%s\n' "$sum"
}

fm_native_grant_check() {  # <file> <task-id> <harness> <pane> <ledger>
  local file=$1 id=$2 harness=$3 pane=$4 ledger=$5
  local snap size keys fields now g_task g_pane g_agent g_session g_written
  FM_NATIVE_GRANT_ERROR=
  FM_NATIVE_GRANT_FINGERPRINT=
  FM_NATIVE_GRANT_SESSION=
  if [ -z "$id" ] || [ -z "$harness" ] || [ -z "$pane" ]; then
    FM_NATIVE_GRANT_ERROR="the task record does not name the task, harness and pane a grant must match"
    return 1
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    FM_NATIVE_GRANT_ERROR="grant '$file' is not a regular file"
    return 1
  fi
  if [ "${file##*/}" != "$id.json" ]; then
    FM_NATIVE_GRANT_ERROR="grant '$file' is not named $id.json"
    return 1
  fi
  # One bounded read; every check and the fingerprint use these same bytes,
  # so a file replaced mid-check cannot change what is spent.
  snap=$(head -c $((FM_NATIVE_GRANT_MAX_BYTES + 1)) < "$file" 2>/dev/null; printf x) || snap=
  case "$snap" in
    *x) snap=${snap%x} ;;
    *)
      FM_NATIVE_GRANT_ERROR="grant '$file' cannot be read"
      return 1
      ;;
  esac
  size=$(printf '%s' "$snap" | wc -c | tr -d '[:space:]')
  if [ "$size" -eq 0 ] || [ "$size" -gt "$FM_NATIVE_GRANT_MAX_BYTES" ]; then
    FM_NATIVE_GRANT_ERROR="grant '$file' is empty or larger than $FM_NATIVE_GRANT_MAX_BYTES bytes"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    FM_NATIVE_GRANT_ERROR="jq is required to read a native grant"
    return 1
  }
  # Exactly one JSON value, and it is a flat object.
  if ! jq -se 'length == 1 and (.[0] | type == "object")
      and ([.[0][] | type] | all(. != "object" and . != "array"))' \
      <<<"$snap" >/dev/null 2>&1; then
    FM_NATIVE_GRANT_ERROR="grant '$file' is not exactly one flat JSON object"
    return 1
  fi
  # Every top-level key occurrence, in file order and JSON-encoded, so a
  # repeated key (which a plain parse silently collapses to its last value) is
  # counted twice and no key text is ever word-split or globbed.
  keys=$(jq -nc --stream 'inputs | select(length == 2 and (.[0] | length) == 1) | .[0][0]' \
    <<<"$snap" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ') || keys=
  if [ "$keys" != '"agent" "pane" "session" "task" "written" ' ]; then
    FM_NATIVE_GRANT_ERROR="grant '$file' must carry exactly the keys task, pane, agent, session and written, each once"
    return 1
  fi
  fields=$(jq -r '
      if (.task | type) == "string" and (.pane | type) == "string"
        and (.agent | type) == "string" and (.session | type) == "string"
        and (.written | type) == "number" and .written == (.written | floor)
        and ([.task, .pane, .agent, .session] | all(test("^[^\t\n]+$")))
      then [.task, .pane, .agent, .session, (.written | tostring)] | join("\t")
      else empty end' <<<"$snap" 2>/dev/null) || fields=
  if [ -z "$fields" ]; then
    FM_NATIVE_GRANT_ERROR="grant '$file' has a field of the wrong type"
    return 1
  fi
  IFS=$'\t' read -r g_task g_pane g_agent g_session g_written <<EOF
$fields
EOF
  if [ "$g_task" != "$id" ]; then
    FM_NATIVE_GRANT_ERROR="grant names task '$g_task', not $id"
    return 1
  fi
  if [ "$g_agent" != "$harness" ]; then
    FM_NATIVE_GRANT_ERROR="grant names harness '$g_agent', but task $id records '$harness'"
    return 1
  fi
  if [ "$g_pane" != "$pane" ]; then
    FM_NATIVE_GRANT_ERROR="grant names pane '$g_pane', but task $id records '$pane'"
    return 1
  fi
  if ! printf '%s\n' "$g_session" \
      | grep -Eqx '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
    FM_NATIVE_GRANT_ERROR="grant's session is not a native conversation id"
    return 1
  fi
  case "$g_written" in
    '' | *[!0-9]* | ?????????????*)
      FM_NATIVE_GRANT_ERROR="grant's written time is not a plausible Unix time"
      return 1
      ;;
  esac
  now=$(date +%s)
  if [ "$g_written" -gt "$now" ] || [ $((now - g_written)) -gt "$FM_NATIVE_GRANT_MAX_AGE" ]; then
    FM_NATIVE_GRANT_ERROR="grant was written outside the last $FM_NATIVE_GRANT_MAX_AGE seconds"
    return 1
  fi
  FM_NATIVE_GRANT_FINGERPRINT=$(printf '%s' "$snap" | fm_native_grant_fingerprint) || {
    FM_NATIVE_GRANT_FINGERPRINT=
    FM_NATIVE_GRANT_ERROR="grant '$file' cannot be fingerprinted"
    return 1
  }
  if [ -L "$ledger" ] || { [ -e "$ledger" ] && [ ! -f "$ledger" ]; }; then
    FM_NATIVE_GRANT_FINGERPRINT=
    FM_NATIVE_GRANT_ERROR="grant spend ledger '$ledger' is not a regular file"
    return 1
  fi
  if [ -e "$ledger" ] && ! [ -r "$ledger" ]; then
    FM_NATIVE_GRANT_FINGERPRINT=
    FM_NATIVE_GRANT_ERROR="grant spend ledger '$ledger' cannot be read"
    return 1
  fi
  if [ -f "$ledger" ] && grep -qxF "$FM_NATIVE_GRANT_FINGERPRINT" "$ledger"; then
    FM_NATIVE_GRANT_FINGERPRINT=
    FM_NATIVE_GRANT_ERROR="this grant was already used for a recovery attempt"
    return 1
  fi
  FM_NATIVE_GRANT_SESSION=$g_session
}

fm_native_grant_spend() {  # <ledger>
  local ledger=$1
  FM_NATIVE_GRANT_ERROR=
  [ -n "${FM_NATIVE_GRANT_FINGERPRINT:-}" ] || {
    FM_NATIVE_GRANT_ERROR="no checked grant to record"
    return 1
  }
  if [ -L "$ledger" ] || { [ -e "$ledger" ] && [ ! -f "$ledger" ]; }; then
    FM_NATIVE_GRANT_ERROR="grant spend ledger '$ledger' is not a regular file"
    return 1
  fi
  if ! { printf '%s\n' "$FM_NATIVE_GRANT_FINGERPRINT" >> "$ledger" 2>/dev/null \
    && grep -qxF "$FM_NATIVE_GRANT_FINGERPRINT" "$ledger"; }; then
    FM_NATIVE_GRANT_ERROR="grant spend ledger '$ledger' could not be written"
    return 1
  fi
}
