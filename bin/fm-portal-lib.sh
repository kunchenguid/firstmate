#!/usr/bin/env bash
# shellcheck disable=SC2034 # This sourced library publishes state for callers.
# Shared mechanics for the private AI Department portal connector.
#
# This file is sourced, never executed.
# It owns the connector configuration schema, private durable record schemas,
# endpoint validation, bounded HTTP transport, cursor/inbox/outbox state, task
# links, and retention mechanics used by fm-portal-*.sh.
#
# Local configuration (exact schema):
#   config/portal-connector.json, mode 0600, one ordinary link, <=8192 bytes
#   {"base_url":"http://127.0.0.1:8201","bearer_token":"..."}
# Unknown keys, control bytes, an empty or >4096-byte token, and unsafe URLs are
# rejected. HTTP is accepted only for loopback; a remote endpoint must use HTTPS.
# The bearer token is read only from this file and is sent to curl through an
# owner-only header file, never an argument or exported environment variable.
#
# Durable state under state/portal/:
#   cursor.json       fm-portal-cursor.v1, endpoint-bound monotonic last_id
#   inbox/<id>.json   canonical validated captain message, private immutable data
#   records/<id>.json fm-portal-record.v1 processing/wake state, no message body
#   outbox/<id>.json  fm-portal-outbox.v1 stable idempotency key + private reply
#   error             one deduplicated body-free connector error code
# Completed triplets are retained seven days by default and capped at 256.

FMP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FMP_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FMP_LIB_DIR/.." && pwd)}"
FMP_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FMP_ROOT}}"
FMP_STATE="${FM_STATE_OVERRIDE:-$FMP_HOME/state}"
FMP_CONFIG="${FM_CONFIG_OVERRIDE:-$FMP_HOME/config}"
FMP_CONFIG_FILE="$FMP_CONFIG/portal-connector.json"
FMP_PORTAL_DIR="$FMP_STATE/portal"
FMP_INBOX="$FMP_PORTAL_DIR/inbox"
FMP_RECORDS="$FMP_PORTAL_DIR/records"
FMP_OUTBOX="$FMP_PORTAL_DIR/outbox"
FMP_CURSOR="$FMP_PORTAL_DIR/cursor.json"
FMP_ERROR="$FMP_PORTAL_DIR/error"
FMP_LOCK="$FMP_PORTAL_DIR/.lock"
FMP_MAX_CONFIG_BYTES=8192
FMP_MAX_TOKEN_BYTES=4096
FMP_MAX_RESPONSE_BYTES=262144
FMP_MAX_MESSAGE_CHARS=4000
FMP_MAX_ID=9007199254740991
FMP_DEFAULT_BASE_URL=http://127.0.0.1:8201
FMP_DEFAULT_BATCH=20
FMP_DEFAULT_RETENTION_SECS=604800
FMP_DEFAULT_RETENTION_COUNT=256
FMP_DEFAULT_CLAIM_LEASE_SECS=600
FMP_CONFIG_ERROR=
FMP_BASE_URL=
FMP_TOKEN=
FMP_HTTP_CODE=
FMP_HTTP_ERROR=
FMP_RECORD_STATE=
FMP_RECORD_TASK=
FMP_RECORD_WAKE=
FMP_OUTBOX_STATE=
FMP_OUTBOX_MESSAGE_ID=

# Reuse the established guarded-private-artifact publisher rather than creating
# a second implementation of its symlink, hard-link, mode, device, and atomic
# publication contract.
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$FMP_LIB_DIR/fm-x-lib.sh"
# Portable private-file identity helpers.
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$FMP_LIB_DIR/fm-pr-lib.sh"
# Callers that mutate records source fm-wake-lib.sh for portable owner locks.
# Keeping that source out of this library preserves detect-only bootstrap's
# no-write contract because fm-wake-lib.sh prepares state at source time.

fmp_now() {
  local now=${FM_PORTAL_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#now}" -le 18 ] || return 1
  printf '%s\n' "$now"
}

fmp_id_valid() {
  local id=${1:-}
  case "$id" in ''|0|*[!0-9]*) return 1 ;; esac
  [ "${#id}" -le 16 ] || return 1
  [ "$id" -le "$FMP_MAX_ID" ] 2>/dev/null
}

fmp_task_id_valid() {
  fm_pr_task_id_valid "${1:-}"
}

fmp_sha256_file() {
  fm_pr_sha256 "$1"
}

fmp_config_file_identity_valid() {
  local file=${1:-$FMP_CONFIG_FILE} parent device bytes
  parent=${file%/*}
  [ "$parent" != "$file" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  device=$(fm_pr_file_device "$parent") || return 1
  fm_pr_private_file_valid "$file" 600 "$device" || return 1
  bytes=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$FMP_MAX_CONFIG_BYTES" ]
}

# Validate URLs without putting them in a process argument.
# Accepted forms are an HTTP loopback origin, or an HTTPS origin with an
# optional path prefix. Userinfo, query strings, fragments, controls, and a
# trailing slash are rejected so endpoint construction is unambiguous.
fmp_base_url_valid() {
  local url=$1
  [ -n "$url" ] && [ "${#url}" -le 2048 ] || return 1
  printf '%s' "$url" | jq -eR '
    (explode | all(. > 32 and . != 127))
    and (endswith("/") | not)
    and (contains("@") | not)
    and (contains("?") | not)
    and (contains("#") | not)
    and (
      test("^http://(127\\.0\\.0\\.1|localhost)(:[0-9]{1,5})?$")
      or test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~!$&()*+,;=:@%/-]*)?$")
    )
  ' >/dev/null 2>&1
}

# fmp_load_config [path]: populate FMP_BASE_URL/FMP_TOKEN or return non-zero and
# set a body-free FMP_CONFIG_ERROR suitable for operator diagnostics.
fmp_load_config() {
  local file=${1:-$FMP_CONFIG_FILE} base token
  FMP_BASE_URL=
  FMP_TOKEN=
  FMP_CONFIG_ERROR=
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    FMP_CONFIG_ERROR=absent
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    FMP_CONFIG_ERROR=missing-jq
    return 1
  fi
  if ! fmp_config_file_identity_valid "$file"; then
    FMP_CONFIG_ERROR=unsafe-file
    return 1
  fi
  if ! jq -e --argjson token_max "$FMP_MAX_TOKEN_BYTES" '
    type == "object"
    and (keys | sort) == ["base_url", "bearer_token"]
    and (.base_url | type == "string" and length > 0 and length <= 2048)
    and (.bearer_token | type == "string" and length > 0 and length <= $token_max)
    and (.bearer_token | explode | all(. >= 32 and . != 127))
  ' "$file" >/dev/null 2>&1; then
    FMP_CONFIG_ERROR=invalid-json
    return 1
  fi
  base=$(jq -r '.base_url' "$file" 2>/dev/null) || {
    FMP_CONFIG_ERROR=invalid-json
    return 1
  }
  token=$(jq -r '.bearer_token' "$file" 2>/dev/null) || {
    FMP_CONFIG_ERROR=invalid-json
    return 1
  }
  if ! fmp_base_url_valid "$base"; then
    FMP_CONFIG_ERROR=invalid-base-url
    return 1
  fi
  FMP_BASE_URL=$base
  FMP_TOKEN=$token
  return 0
}

fmp_poll_shim_content() {
  local home=$1 root=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-bootstrap.sh - authenticated portal poll shim.' \
    '# Registered by byte hash; portal text is never published as runnable code.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-portal-poll.sh")"
}

fmp_poll_shim_valid() {
  local file=$1 home=$2 root=$3
  fmx_single_link_file_mode_valid "$file" 700 || return 1
  cmp -s "$file" <(fmp_poll_shim_content "$home" "$root")
}

fmp_private_dir_prepare() {
  fmx_private_artifact_dir_prepare "$1" >/dev/null
}

fmp_publish() {
  fmx_private_artifact_publish_stdin "$1" "$2" 600
}

fmp_publish_once() {
  fmx_private_artifact_publish_stdin_once "$1" "$2" 600
}

fmp_file_valid() {
  fmx_private_artifact_file_valid "$1" "$2" 600
}

fmp_portal_prepare() {
  fmp_private_dir_prepare "$FMP_PORTAL_DIR" || return 1
  fmp_private_dir_prepare "$FMP_INBOX" || return 1
  fmp_private_dir_prepare "$FMP_RECORDS" || return 1
  fmp_private_dir_prepare "$FMP_OUTBOX" || return 1
}

fmp_auth_header_file() {
  local key=${1:-} file
  case "$FMP_TOKEN$key" in *$'\n'*|*$'\r'*) return 1 ;; esac
  file=$(umask 077; mktemp "$FMP_PORTAL_DIR/.headers.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  {
    printf 'Authorization: Bearer %s\n' "$FMP_TOKEN"
    [ -z "$key" ] || printf 'Idempotency-Key: %s\n' "$key"
  } > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# One bounded request. Payload contents and credentials are passed by private
# files; only the non-secret URL and file paths appear in curl's argv.
fmp_http_request() {
  local method=$1 url=$2 output=$3 payload=${4:-} key=${5:-} headers rc
  FMP_HTTP_CODE=
  FMP_HTTP_ERROR=
  command -v curl >/dev/null 2>&1 || { FMP_HTTP_ERROR=missing-curl; return 1; }
  headers=$(fmp_auth_header_file "$key") || { FMP_HTTP_ERROR=invalid-credentials; return 1; }
  trap 'rm -f "$headers"' RETURN
  if [ "$method" = GET ]; then
    FMP_HTTP_CODE=$(curl --connect-timeout 2 --max-time 5 --max-filesize "$FMP_MAX_RESPONSE_BYTES" \
      --retry 1 --retry-delay 0 --retry-connrefused -sS -o "$output" -w '%{http_code}' \
      -H "@$headers" -H 'Accept: application/json' "$url" 2>/dev/null)
    rc=$?
  else
    [ -r "$payload" ] || { rm -f "$headers"; trap - RETURN; FMP_HTTP_ERROR=missing-payload; return 1; }
    FMP_HTTP_CODE=$(curl --connect-timeout 2 --max-time 8 --max-filesize "$FMP_MAX_RESPONSE_BYTES" \
      --retry 2 --retry-delay 0 --retry-connrefused --retry-all-errors \
      -sS -o "$output" -w '%{http_code}' -X POST \
      -H "@$headers" -H 'Accept: application/json' -H 'Content-Type: application/json' \
      --data-binary "@$payload" "$url" 2>/dev/null)
    rc=$?
  fi
  rm -f "$headers"
  trap - RETURN
  if [ "$rc" -ne 0 ]; then
    FMP_HTTP_ERROR=network
    return 1
  fi
  case "$FMP_HTTP_CODE" in ''|*[!0-9]*) FMP_HTTP_ERROR=invalid-status; return 1 ;; esac
  if [ -f "$output" ]; then
    local bytes
    bytes=$(wc -c < "$output" 2>/dev/null | tr -d '[:space:]') || bytes=
    case "$bytes" in ''|*[!0-9]*) FMP_HTTP_ERROR=oversized-response; return 1 ;; esac
    [ "$bytes" -le "$FMP_MAX_RESPONSE_BYTES" ] || { FMP_HTTP_ERROR=oversized-response; return 1; }
  fi
  return 0
}

fmp_error_emit_once() {
  local code=$1
  case "$code" in ''|*[!A-Za-z0-9._:-]*) code=unknown ;; esac
  fmp_portal_prepare 2>/dev/null || {
    printf 'portal-error %s\n' "$code"
    return 0
  }
  if fmp_file_valid "$FMP_PORTAL_DIR" error \
    && [ "$(cat "$FMP_ERROR" 2>/dev/null)" = "$code" ]; then
    return 0
  fi
  printf '%s\n' "$code" | fmp_publish "$FMP_PORTAL_DIR" error 2>/dev/null || true
  printf 'portal-error %s\n' "$code"
}

fmp_error_clear() {
  fmp_private_dir_prepare "$FMP_PORTAL_DIR" 2>/dev/null || return 0
  rm -f "$FMP_ERROR" 2>/dev/null || true
}

fmp_cursor_load() {
  local base=$1
  FMP_CURSOR_ID=0
  if [ ! -e "$FMP_CURSOR" ] && [ ! -L "$FMP_CURSOR" ]; then
    return 0
  fi
  if ! fmp_file_valid "$FMP_PORTAL_DIR" cursor.json; then
    return 1
  fi
  jq -e --arg schema fm-portal-cursor.v1 --arg base "$base" --argjson max "$FMP_MAX_ID" '
    type == "object" and (keys | sort) == ["base_url", "last_id", "schema"]
    and .schema == $schema and .base_url == $base
    and (.last_id | type == "number" and floor == . and . >= 0 and . <= $max)
  ' "$FMP_CURSOR" >/dev/null 2>&1 || return 1
  FMP_CURSOR_ID=$(jq -r '.last_id' "$FMP_CURSOR") || return 1
}

fmp_cursor_store() {
  local base=$1 id=$2
  fmp_id_valid "$id" || [ "$id" = 0 ] || return 1
  jq -cn --arg schema fm-portal-cursor.v1 --arg base "$base" --argjson id "$id" \
    '{schema:$schema,base_url:$base,last_id:$id}' \
    | fmp_publish "$FMP_PORTAL_DIR" cursor.json
}

FMP_RECORD_SCHEMA_JQ='
    type == "object"
    and ((keys - ["schema","request_id","request_sha256","state","task_id","received_at","updated_at","claimed_at"]) | length == 0)
    and .schema == $schema and .request_id == $id
    and (.request_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.state | IN("pending","queued","claimed","linked","replying","complete","conflict"))
    and ((.task_id // "") | type == "string" and length <= 64)
    and (.received_at | type == "number" and floor == . and . >= 0)
    and (.updated_at | type == "number" and floor == . and . >= 0)
    and ((.claimed_at // 0) | type == "number" and floor == . and . >= 0)'

fmp_record_validate_file() {
  local file=$1 id=$2
  fmp_id_valid "$id" || return 1
  fmp_file_valid "$FMP_RECORDS" "$id.json" || return 1
  jq -e --arg schema fm-portal-record.v1 --argjson id "$id" \
    "$FMP_RECORD_SCHEMA_JQ" "$file" >/dev/null 2>&1
}

# One validated pass over records/. Every file gets the same per-file name and
# private-identity checks as fmp_record_validate_file, then a single jq
# invocation schema-validates all of them and emits one
# "id<TAB>state<TAB>claimed_at<TAB>task_id" line per record, sorted by id
# ascending. Any invalid name, identity, schema, or short/extra payload fails
# the whole scan so callers never act on a partially valid directory.
fmp_records_scan() {
  local file id files=() out lines
  for file in "$FMP_RECORDS"/*.json; do
    [ -e "$file" ] || continue
    id=${file##*/}; id=${id%.json}
    fmp_id_valid "$id" || return 1
    fmp_file_valid "$FMP_RECORDS" "$id.json" || return 1
    files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  out=$(jq -r --arg schema fm-portal-record.v1 '
    (input_filename | split("/") | last | rtrimstr(".json") | tonumber) as $id
    | if '"$FMP_RECORD_SCHEMA_JQ"'
      then [($id | tostring), .state, ((.claimed_at // 0) | tostring), (.task_id // "")] | join("\t")
      else error("invalid record") end
  ' "${files[@]}" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  lines=$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')
  [ "$lines" -eq "${#files[@]}" ] || return 1
  printf '%s\n' "$out" | sort -n
}

fmp_record_load() {
  local id=$1 file="$FMP_RECORDS/$1.json"
  FMP_RECORD_STATE=
  FMP_RECORD_TASK=
  FMP_RECORD_WAKE=
  fmp_record_validate_file "$file" "$id" || return 1
  FMP_RECORD_STATE=$(jq -r '.state' "$file") || return 1
  FMP_RECORD_TASK=$(jq -r '.task_id // ""' "$file") || return 1
  FMP_RECORD_WAKE=$(jq -r '.claimed_at // 0' "$file") || return 1
}

fmp_record_create_once() {
  local id=$1 hash=$2 now record rc
  fmp_id_valid "$id" || return 2
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  now=$(fmp_now) || return 2
  record=$(jq -cn --arg schema fm-portal-record.v1 --argjson id "$id" --arg hash "$hash" --argjson now "$now" \
    '{schema:$schema,request_id:$id,request_sha256:$hash,state:"pending",task_id:"",received_at:$now,updated_at:$now,claimed_at:0}') || return 2
  printf '%s\n' "$record" | fmp_publish_once "$FMP_RECORDS" "$id.json"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      fmp_record_validate_file "$FMP_RECORDS/$id.json" "$id" || return 2
      [ "$(jq -r '.request_sha256' "$FMP_RECORDS/$id.json")" = "$hash" ] || return 2
      return 1
      ;;
    *) return 2 ;;
  esac
}

fmp_record_set_state() {
  local id=$1 state=$2 task=${3:-} claimed=${4:-0} now file
  case "$state" in pending|queued|claimed|linked|replying|complete|conflict) ;; *) return 1 ;; esac
  file="$FMP_RECORDS/$id.json"
  fmp_record_validate_file "$file" "$id" || return 1
  now=$(fmp_now) || return 1
  jq -c --arg state "$state" --arg task "$task" --argjson now "$now" --argjson claimed "$claimed" \
    '.state=$state | .task_id=$task | .updated_at=$now | .claimed_at=$claimed' "$file" \
    | fmp_publish "$FMP_RECORDS" "$id.json"
}

fmp_inbox_validate_file() {
  local file=$1 id=$2
  fmp_file_valid "$FMP_INBOX" "$id.json" || return 1
  jq -e --argjson id "$id" --argjson max "$FMP_MAX_ID" --argjson chars "$FMP_MAX_MESSAGE_CHARS" '
    type == "object" and (keys | sort) == ["body", "created_at", "id"]
    and .id == $id and .id > 0 and .id <= $max
    and (.body | type == "string" and length > 0 and length <= $chars)
    and (.created_at | type == "string" and length > 0 and length <= 128)
  ' "$file" >/dev/null 2>&1
}

fmp_outbox_validate_file() {
  local file=$1 id=$2
  fmp_file_valid "$FMP_OUTBOX" "$id.json" || return 1
  jq -e --arg schema fm-portal-outbox.v1 --argjson id "$id" --argjson chars "$FMP_MAX_MESSAGE_CHARS" --argjson max "$FMP_MAX_ID" '
    type == "object"
    and (keys | sort) == ["body","body_sha256","created_at","idempotency_key","portal_message_id","request_id","schema","state","updated_at"]
    and .schema == $schema and .request_id == $id
    and (.idempotency_key | type == "string" and length >= 16 and length <= 128 and test("^[!-~]+$"))
    and (.body | type == "string" and length > 0 and length <= $chars)
    and (.body_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.state | IN("pending","posted","complete","conflict"))
    and ((.portal_message_id == null) or (.portal_message_id | type == "number" and floor == . and . > 0 and . <= $max))
    and (.created_at | type == "number" and floor == . and . >= 0)
    and (.updated_at | type == "number" and floor == . and . >= 0)
  ' "$file" >/dev/null 2>&1
}

fmp_outbox_load() {
  local id=$1 file="$FMP_OUTBOX/$1.json"
  FMP_OUTBOX_STATE=
  FMP_OUTBOX_MESSAGE_ID=
  fmp_outbox_validate_file "$file" "$id" || return 1
  FMP_OUTBOX_STATE=$(jq -r '.state' "$file") || return 1
  FMP_OUTBOX_MESSAGE_ID=$(jq -r '.portal_message_id // ""' "$file") || return 1
}

fmp_idempotency_key() {
  local random
  random=$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
  [[ "$random" =~ ^[0-9a-f]{48}$ ]] || return 1
  printf 'fm-portal-v1-%s\n' "$random"
}

fmp_outbox_create_once() {
  local id=$1 body_file=$2 now key hash out rc
  fmp_id_valid "$id" || return 2
  [ -f "$body_file" ] && [ ! -L "$body_file" ] || return 2
  hash=$(fmp_sha256_file "$body_file") || return 2
  now=$(fmp_now) || return 2
  key=$(fmp_idempotency_key) || return 2
  out=$(jq -cn --arg schema fm-portal-outbox.v1 --argjson id "$id" --arg key "$key" \
    --rawfile body "$body_file" --arg hash "$hash" --argjson now "$now" \
    '{schema:$schema,request_id:$id,idempotency_key:$key,body:$body,body_sha256:$hash,state:"pending",portal_message_id:null,created_at:$now,updated_at:$now}') || return 2
  printf '%s\n' "$out" | fmp_publish_once "$FMP_OUTBOX" "$id.json"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      fmp_outbox_validate_file "$FMP_OUTBOX/$id.json" "$id" || return 2
      [ "$(jq -r '.body_sha256' "$FMP_OUTBOX/$id.json")" = "$hash" ] || return 2
      return 1
      ;;
    *) return 2 ;;
  esac
}

fmp_outbox_set_state() {
  local id=$1 state=$2 message_id=${3:-null} now file
  case "$state" in pending|posted|complete|conflict) ;; *) return 1 ;; esac
  if [ "$message_id" != null ]; then fmp_id_valid "$message_id" || return 1; fi
  file="$FMP_OUTBOX/$id.json"
  fmp_outbox_validate_file "$file" "$id" || return 1
  now=$(fmp_now) || return 1
  jq -c --arg state "$state" --argjson mid "$message_id" --argjson now "$now" \
    '.state=$state | .portal_message_id=$mid | .updated_at=$now' "$file" \
    | fmp_publish "$FMP_OUTBOX" "$id.json"
}

fmp_meta_get() {
  local file=$1 key=$2 line
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}"
}

fmp_meta_link_set() {
  local meta=$1 id=$2 tmp dir base
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fmp_id_valid "$id" || return 1
  dir=${meta%/*}; base=${meta##*/}
  tmp=$(mktemp "$dir/.${base}.fm-portal.XXXXXX") || return 1
  { grep -v '^portal_request=' "$meta" || true; } > "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'portal_request=%s\n' "$id" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

fmp_meta_link_clear() {
  local meta=$1 tmp dir base
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  dir=${meta%/*}; base=${meta##*/}
  tmp=$(mktemp "$dir/.${base}.fm-portal.XXXXXX") || return 1
  { grep -v '^portal_request=' "$meta" || true; } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

# Print the numerically oldest request whose processing record is not complete.
# The portal acknowledgement endpoint is cumulative, so this ordering is the
# client-side backstop that prevents a later response from acknowledging an
# earlier request before its own durable response exists.
fmp_oldest_open_id() {
  local scan id state _rest
  scan=$(fmp_records_scan) || return 2
  [ -n "$scan" ] || return 1
  while IFS=$'\t' read -r id state _rest; do
    [ -n "$id" ] || continue
    [ "$state" = complete ] && continue
    printf '%s\n' "$id"
    return 0
  done <<< "$scan"
  return 1
}

# Exit 0 when any lower-id durable request has not completed.
fmp_prior_request_incomplete() {
  local target=$1 scan id state _rest
  fmp_id_valid "$target" || return 0
  scan=$(fmp_records_scan) || return 0
  [ -n "$scan" ] || return 1
  while IFS=$'\t' read -r id state _rest; do
    [ -n "$id" ] || continue
    [ "$id" -lt "$target" ] 2>/dev/null || continue
    [ "$state" = complete ] || return 0
  done <<< "$scan"
  return 1
}

fmp_task_for_request() {
  local id=$1 meta linked found=
  for meta in "$FMP_STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    linked=$(fmp_meta_get "$meta" portal_request)
    [ "$linked" = "$id" ] || continue
    [ -z "$found" ] || return 2
    found=${meta##*/}; found=${found%.meta}
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fmp_retention_values() {
  FMP_RETENTION_SECS=${FM_PORTAL_RETENTION_SECS:-$FMP_DEFAULT_RETENTION_SECS}
  FMP_RETENTION_COUNT=${FM_PORTAL_RETENTION_COUNT:-$FMP_DEFAULT_RETENTION_COUNT}
  case "$FMP_RETENTION_SECS" in ''|*[!0-9]*) FMP_RETENTION_SECS=$FMP_DEFAULT_RETENTION_SECS ;; esac
  case "$FMP_RETENTION_COUNT" in ''|*[!0-9]*|0) FMP_RETENTION_COUNT=$FMP_DEFAULT_RETENTION_COUNT ;; esac
  [ "$FMP_RETENTION_SECS" -le 2592000 ] || FMP_RETENTION_SECS=2592000
  [ "$FMP_RETENTION_COUNT" -le 1024 ] || FMP_RETENTION_COUNT=1024
}

fmp_file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Remove only complete, schema-valid record triplets after the bounded window,
# then cap the remaining completed records oldest-first. Pending work is never
# pruned automatically.
fmp_prune_completed() {
  local scan now file id state _claimed _task m age count remove_n keep=()
  fmp_retention_values
  now=$(fmp_now) || return 0
  scan=$(fmp_records_scan) || return 0
  [ -n "$scan" ] || return 0
  while IFS=$'\t' read -r id state _claimed _task; do
    [ -n "$id" ] || continue
    [ "$state" = complete ] || continue
    file="$FMP_RECORDS/$id.json"
    m=$(fmp_file_mtime "$file") || continue
    age=$((now - m))
    if [ "$age" -gt "$FMP_RETENTION_SECS" ]; then
      rm -f "$file" "$FMP_INBOX/$id.json" "$FMP_OUTBOX/$id.json" 2>/dev/null || true
    else
      keep+=("$m"$'\t'"$id")
    fi
  done <<< "$scan"
  count=${#keep[@]}
  [ "$count" -gt "$FMP_RETENTION_COUNT" ] || return 0
  remove_n=$((count - FMP_RETENTION_COUNT))
  printf '%s\n' "${keep[@]}" | sort -n | head -n "$remove_n" \
    | while IFS=$'\t' read -r _mtime id; do
        rm -f "$FMP_RECORDS/$id.json" "$FMP_INBOX/$id.json" "$FMP_OUTBOX/$id.json" 2>/dev/null || true
      done
}
