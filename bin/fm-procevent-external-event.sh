#!/usr/bin/env bash
# fm-procevent-external-event.sh - typed local ingress for untrusted events.
#
# Usage:
#   fm-procevent-external-event.sh ingest <source> <delivery-key> < payload
#   fm-procevent-external-event.sh classify <result-file>
#   fm-procevent-external-event.sh metadata <result-file>
#   fm-procevent-external-event.sh payload <result-file>
#   fm-procevent-external-event.sh --help
#
# `ingest` is the stable local boundary for an authenticated external webhook
# forwarder or reconciliation job.
# It does not authenticate a network request and deliberately does not provide
# an HTTP listener.
# The caller must authenticate outside Firstmate, then invoke this command
# locally or over an operator-controlled SSH route.
#
# Every byte on stdin is untrusted input, never captain text or authorization.
# The bytes are stored in the existing process-event inbox at mode 0600 before
# a normalized `procevent external-event ...` wake is appended.
# The payload never appears in the wake queue or captain inbox.
# A source-scoped delivery key deduplicates retries durably; callers that want
# webhook and reconciliation observations to coalesce must give the same
# authoritative object revision the same delivery key.
#
# The result envelope is owned here:
#   schema=fm-external-event.v1
#   source=<validated source slug>
#   delivery=<validated source-scoped delivery key>
#   --
#   <untrusted payload bytes>
#
# Environment:
#   FM_HOME                      operational home
#   FM_STATE_OVERRIDE            state directory override
#   FM_EXTERNAL_EVENT_MAX_BYTES  maximum payload size, default 1048576
set -u
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ADAPTER=external-event
SCHEMA=fm-external-event.v1
MAX_BYTES=${FM_EXTERNAL_EVENT_MAX_BYTES:-1048576}
PAYLOAD_TMP=
ENVELOPE_TMP=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

usage() {
  sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-procevent-external-event: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  rm -f -- "$PAYLOAD_TMP" "$ENVELOPE_TMP"
}

source_valid() {
  case ${1-} in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

delivery_valid() {
  case ${1-} in
    ''|*[!A-Za-z0-9._:@+-]*) return 1 ;;
  esac
  [ "${#1}" -le 240 ]
}

max_bytes_valid() {
  case $MAX_BYTES in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  [ "$MAX_BYTES" -le 16777216 ]
}

result_read_metadata() {
  local result=$1 schema_line source_line delivery_line separator
  FM_EXTERNAL_EVENT_SOURCE=
  FM_EXTERNAL_EVENT_DELIVERY=
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  {
    IFS= read -r schema_line \
      && IFS= read -r source_line \
      && IFS= read -r delivery_line \
      && IFS= read -r separator
  } < "$result" || return 1
  [ "$schema_line" = "schema=$SCHEMA" ] || return 1
  [ "$separator" = -- ] || return 1
  case $source_line in source=*) ;; *) return 1 ;; esac
  case $delivery_line in delivery=*) ;; *) return 1 ;; esac
  FM_EXTERNAL_EVENT_SOURCE=${source_line#source=}
  FM_EXTERNAL_EVENT_DELIVERY=${delivery_line#delivery=}
  source_valid "$FM_EXTERNAL_EVENT_SOURCE" || return 1
  delivery_valid "$FM_EXTERNAL_EVENT_DELIVERY" || return 1
}

event_source_id() {
  local source=$1 delivery=$2 identity hash
  identity=$(umask 077; mktemp "$STATE/.external-event-identity.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$source" "$delivery" > "$identity"; then
    rm -f -- "$identity"
    return 1
  fi
  hash=$(fm_pr_sha256 "$identity") || {
    rm -f -- "$identity"
    return 1
  }
  rm -f -- "$identity"
  printf 'event-%s\n' "${hash:0:58}"
}

wake_is_queued() {
  local key=$1 queued
  while IFS= read -r queued; do
    [ "$queued" = "$key" ] && return 0
  done < <(fm_wake_queued_keys check)
  return 1
}

publish_locked() {
  local id=$1 seq=$2 key line
  fm_procevent_is_handled "$STATE" "$id" "$seq" && return 0
  key="procevent:$id:$seq"
  wake_is_queued "$key" && return 0
  line=$(fm_procevent_event_line "$ADAPTER" "$id" "$seq") || return 1
  fm_wake_append check "$key" "check: $line"
}

action_ingest() {
  local source=${1-} delivery=${2-} id result existing seq bytes status=0
  [ "$#" -eq 2 ] || die 'usage: ingest <source> <delivery-key> < payload'
  source_valid "$source" || die 'source must be a lowercase alphanumeric dash slug of at most 32 characters'
  delivery_valid "$delivery" \
    || die 'delivery key must use only A-Z, a-z, 0-9, dot, underscore, colon, at, plus, or dash and be at most 240 characters'
  max_bytes_valid || die 'FM_EXTERNAL_EVENT_MAX_BYTES must be a whole number from 1 to 16777216'
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || mkdir -p "$STATE" || die "cannot create state directory: $STATE"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable: $STATE"

  PAYLOAD_TMP=$(mktemp "$STATE/.external-event-payload.XXXXXX") \
    || die 'cannot create private payload staging file'
  ENVELOPE_TMP=$(mktemp "$STATE/.external-event-envelope.XXXXXX") || {
    rm -f -- "$PAYLOAD_TMP"
    die 'cannot create private envelope staging file'
  }
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  head -c "$((MAX_BYTES + 1))" > "$PAYLOAD_TMP" || die 'cannot read payload from stdin'
  bytes=$(wc -c < "$PAYLOAD_TMP" 2>/dev/null | tr -d '[:space:]') || die 'cannot measure payload'
  case $bytes in ''|*[!0-9]*) die 'cannot measure payload' ;; esac
  [ "$bytes" -le "$MAX_BYTES" ] || die "payload exceeds FM_EXTERNAL_EVENT_MAX_BYTES ($MAX_BYTES)"
  {
    printf 'schema=%s\n' "$SCHEMA"
    printf 'source=%s\n' "$source"
    printf 'delivery=%s\n' "$delivery"
    printf '%s\n' --
    cat "$PAYLOAD_TMP"
  } > "$ENVELOPE_TMP" || die 'cannot build event envelope'

  id=$(event_source_id "$source" "$delivery") || die 'cannot derive event identity'
  fm_procevent_source_lock_acquire "$id" || die "cannot lock event identity: $id"
  existing="$STATE/procevent-inbox/$id.1.result"
  if [ -e "$existing" ]; then
    if ! result_read_metadata "$existing" \
      || [ "$FM_EXTERNAL_EVENT_SOURCE" != "$source" ] \
      || [ "$FM_EXTERNAL_EVENT_DELIVERY" != "$delivery" ]; then
      fm_procevent_source_lock_release "$id"
      die "event identity collision or invalid durable result: $id"
    fi
    result=$existing
    seq=1
    if ! publish_locked "$id" "$seq"; then status=1; fi
    fm_procevent_source_lock_release "$id"
    [ "$status" -eq 0 ] || die "event $id is durable but its wake could not be published"
    printf 'duplicate: %s %s\n' "$id" "$seq"
    return 0
  fi

  result=$(fm_procevent_capture "$STATE" "$id" "$ADAPTER" "$ENVELOPE_TMP") || {
    fm_procevent_source_lock_release "$id"
    die 'cannot durably capture event'
  }
  seq=$(fm_procevent_result_sequence "$result")
  if ! publish_locked "$id" "$seq"; then status=1; fi
  fm_procevent_source_lock_release "$id"
  [ "$status" -eq 0 ] || die "event $id is durable but its wake could not be published"
  printf 'accepted: %s %s\n' "$id" "$seq"
}

action_classify() {
  [ "$#" -eq 1 ] || die 'usage: classify <result-file>'
  if result_read_metadata "$1"; then
    printf 'event\n'
  else
    printf 'invalid\n'
  fi
}

action_metadata() {
  [ "$#" -eq 1 ] || die 'usage: metadata <result-file>'
  result_read_metadata "$1" || die 'invalid external-event result'
  printf 'source=%s\n' "$FM_EXTERNAL_EVENT_SOURCE"
  printf 'delivery=%s\n' "$FM_EXTERNAL_EVENT_DELIVERY"
}

action_payload() {
  [ "$#" -eq 1 ] || die 'usage: payload <result-file>'
  result_read_metadata "$1" || die 'invalid external-event result'
  tail -n +5 -- "$1"
}

case ${1-} in
  ingest) shift; action_ingest "$@" ;;
  classify) shift; action_classify "$@" ;;
  metadata) shift; action_metadata "$@" ;;
  payload) shift; action_payload "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
