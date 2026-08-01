#!/usr/bin/env bash
# Send one private Telegram reply or quiet captain-relevant notification through
# the deterministic rich/plain presentation boundary.
#
# Usage:
#   fm-telegram-send.sh reply <request_id> <receipt_id> --text-file <mode-0600-file> [--approval-id <id>]
#   fm-telegram-send.sh notify <event_kind> <receipt_id> --text-file <mode-0600-file> [--approval-id <id>]
#
# The renderer, not model text, owns Telegram HTML.
# A restart-stable private snapshot is split into at most twelve messages and
# delivered sequentially under one same-chat lock.
# Each part enters dispatching before network I/O; interruption or ambiguous
# transport becomes uncertain and is never retried blindly.
# A definite Telegram entity-parse rejection may fall back once to the
# renderer's readable plain form.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: fm-telegram-send.sh reply <request_id> <receipt_id> --text-file <mode-0600-file> [--approval-id <id>]
       fm-telegram-send.sh notify <event_kind> <receipt_id> --text-file <mode-0600-file> [--approval-id <id>]
EOF
}

mode=${1:-}
shift || true
REQUEST_ID=
EVENT_KIND=
case "$mode" in
  reply)
    REQUEST_ID=${1:-}
    RECEIPT_ID=${2:-}
    shift 2 || true
    fmtg_safe_slug "$REQUEST_ID" 96 || { usage; exit 2; }
    ;;
  notify)
    EVENT_KIND=${1:-}
    RECEIPT_ID=${2:-}
    shift 2 || true
    case "$EVENT_KIND" in
      decision|failure|credential|pr-green|merge|deployment|scout-complete) ;;
      *) exit 0 ;;
    esac
    ;;
  *) usage; exit 2 ;;
esac
fmtg_safe_slug "${RECEIPT_ID:-}" 128 || { usage; exit 2; }

TEXT_FILE=
APPROVAL_ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file)
      [ "$#" -gt 1 ] || { usage; exit 2; }
      TEXT_FILE=$2
      shift 2
      ;;
    --approval-id)
      [ "$#" -gt 1 ] || { usage; exit 2; }
      APPROVAL_ID=$2
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$TEXT_FILE" ] || { usage; exit 2; }
[ -z "$APPROVAL_ID" ] || fmtg_safe_slug "$APPROVAL_ID" 96 || { usage; exit 2; }

if ! fmtg_load_config; then
  echo "telegram send: bridge is disabled or local config is unsafe" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "telegram send: curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "telegram send: jq is required" >&2; exit 1; }
fmtg_prepare_state || { echo "telegram send: private state is unsafe" >&2; exit 1; }

REQUEST_LOCK=
PAYLOAD=
BODY=
PART_TEXT=
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  [ -z "$REQUEST_LOCK" ] || fm_lock_release "$REQUEST_LOCK"
  rm -f -- "$PAYLOAD" "$BODY" "$PART_TEXT"
}
trap cleanup EXIT

"$SCRIPT_DIR/fm-telegram-render.sh" "$RECEIPT_ID" --text-file "$TEXT_FILE" >/dev/null \
  || { echo "telegram send: presentation could not be prepared" >&2; exit 1; }
SNAPSHOT_FILE="$FMTG_STATE/rendered/$RECEIPT_ID.json"
SNAPSHOT=$(fm_private_read_file "$SNAPSHOT_FILE" 600) \
  || { echo "telegram send: presentation snapshot is unavailable or unsafe" >&2; exit 1; }
SOURCE_HASH=$(printf '%s' "$SNAPSHOT" | jq -r '.source_sha256 // empty')
CHUNKS_TOTAL=$(printf '%s' "$SNAPSHOT" | jq -r '.presentation.messages | length')
case "$CHUNKS_TOTAL" in ''|*[!0-9]*|0) echo "telegram send: presentation snapshot is malformed" >&2; exit 1 ;; esac
[ "$CHUNKS_TOTAL" -le 12 ] || { echo "telegram send: presentation snapshot exceeds delivery bounds" >&2; exit 1; }
if [ -n "$APPROVAL_ID" ] && [ "$CHUNKS_TOTAL" -ne 1 ]; then
  echo "telegram send: an approval prompt must fit one exact Telegram message" >&2
  exit 1
fi

RECEIPT_FILE="$FMTG_STATE/outbound/$RECEIPT_ID.json"
existing_state=
approval_reserved=0
if [ "$mode" = reply ]; then
  REQUEST_LOCK=$(fmtg_request_lock_path "$REQUEST_ID") \
    || { echo "telegram send: request identity is unsafe" >&2; exit 1; }
  fm_lock_acquire_wait "$REQUEST_LOCK"
fi

finalize_approval_binding() {
  local receipt=$1 sent_at message_id expires now file raw state approval_receipt approval_request approval_name final_status
  [ -n "$APPROVAL_ID" ] || return 0
  sent_at=$(printf '%s' "$receipt" | jq -r '.sent_at // .updated_at // 0') || return 1
  message_id=$(printf '%s' "$receipt" | jq -r '.telegram_message_id // empty') || return 1
  case "$sent_at:$message_id" in *[!0-9:]*|:*|*:) return 1 ;; esac
  expires=$((sent_at + FMTG_APPROVAL_TTL_SECS))
  now=$(date +%s)
  file="$FMTG_STATE/approvals/$APPROVAL_ID.json"
  state=
  if [ -e "$file" ] || [ -L "$file" ]; then
    raw=$(fm_private_read_file "$file" 600) || return 1
    state=$(printf '%s' "$raw" | jq -r '.status // empty') || return 1
    approval_receipt=$(printf '%s' "$raw" | jq -r '.receipt_id // empty') || return 1
    approval_request=$(printf '%s' "$raw" | jq -r '.request_id // empty') || return 1
    approval_name=$(printf '%s' "$raw" | jq -r '.approval_id // empty') || return 1
    [ "$approval_receipt" = "$RECEIPT_ID" ] \
      && [ "$approval_request" = "$REQUEST_ID" ] \
      && [ "$approval_name" = "$APPROVAL_ID" ] \
      || return 1
    case "$state" in
      pending)
        printf '%s' "$raw" | jq -e --arg message_id "$message_id" --argjson expires "$expires" '
          .telegram_message_id == ($message_id | tonumber) and .expires_at == $expires
        ' >/dev/null 2>&1
        return
        ;;
      expired) return 0 ;;
      preparing) ;;
      *) return 1 ;;
    esac
  fi
  final_status=pending
  if [ "$now" -gt "$expires" ]; then
    [ -n "$state" ] || return 0
    final_status=expired
  fi
  jq -n --arg approval_id "$APPROVAL_ID" --arg receipt_id "$RECEIPT_ID" \
    --arg request_id "$REQUEST_ID" --arg message_id "$message_id" \
    --arg status "$final_status" --argjson at "$sent_at" --argjson expires "$expires" '
      {schema:"firstmate.telegram-approval.v1",approval_id:$approval_id,receipt_id:$receipt_id,request_id:$request_id,
       status:$status,telegram_message_id:($message_id|tonumber),created_at:$at,expires_at:$expires}
    ' | fmtg_json_publish "$FMTG_STATE/approvals" "$APPROVAL_ID.json"
}

finalize_sent_receipt() {
  local receipt=$1 message_id finalized now
  if ! printf '%s' "$receipt" | jq -e --arg receipt_id "$RECEIPT_ID" '
    .schema == "firstmate.telegram-outbound.v1"
    and .receipt_id == $receipt_id
    and .state == "sent"
  ' >/dev/null 2>&1; then
    return 1
  fi
  message_id=$(printf '%s' "$receipt" | jq -r '.telegram_message_id // empty') || return 1
  case "$message_id" in ''|*[!0-9]*) return 1 ;; esac
  finalize_approval_binding "$receipt" || return 1
  if [ "$mode" = reply ]; then
    fmtg_retire_request_locked "$REQUEST_ID" "$RECEIPT_ID" || return 1
  fi
  finalized=$(printf '%s' "$receipt" | jq -r '.post_send_finalized_at // 0') || return 1
  case "$finalized" in ''|*[!0-9]*) return 1 ;; esac
  [ "$finalized" -gt 0 ] && return 0
  now=$(date +%s)
  printf '%s' "$receipt" | jq --argjson at "$now" '
    .sent_at=(.sent_at // .updated_at) | .post_send_finalized_at=$at
  ' \
    | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json"
}

if fm_private_file_valid "$RECEIPT_FILE" 600; then
  existing=$(fm_private_read_file "$RECEIPT_FILE" 600) || exit 1
  existing_state=$(printf '%s' "$existing" | jq -r '.state // empty')
  existing_request=$(printf '%s' "$existing" | jq -r '.request_id // empty')
  existing_kind=$(printf '%s' "$existing" | jq -r '.kind // empty')
  existing_event=$(printf '%s' "$existing" | jq -r '.event_kind // empty')
  existing_approval=$(printf '%s' "$existing" | jq -r '.approval_id // empty')
  existing_hash=$(printf '%s' "$existing" | jq -r '.source_sha256 // empty')
  existing_chunks=$(printf '%s' "$existing" | jq -r '.chunks_total // 0')
  [ "$existing_request" = "$REQUEST_ID" ] \
    && [ "$existing_kind" = "$mode" ] \
    && [ "$existing_event" = "$EVENT_KIND" ] \
    && [ "$existing_approval" = "$APPROVAL_ID" ] \
    && [ "$existing_hash" = "$SOURCE_HASH" ] \
    && [ "$existing_chunks" = "$CHUNKS_TOTAL" ] \
    || { echo "telegram send: receipt identity collision" >&2; exit 1; }
  case "$existing_state" in
    sent)
      message_id=$(printf '%s' "$existing" | jq -r '.telegram_message_id')
      finalize_sent_receipt "$existing" \
        || { echo "telegram send: sent receipt finalization is incomplete" >&2; exit 1; }
      rm -f -- "$SNAPSHOT_FILE" 2>/dev/null || true
      printf 'sent %s %s\n' "$RECEIPT_ID" "$message_id"
      exit 0
      ;;
    uncertain)
      echo "telegram send: prior delivery outcome is uncertain; reconcile before any retry" >&2
      exit 3
      ;;
    definite-failure)
      echo "telegram send: prior definite failure is retained; use a new receipt only after resolving it" >&2
      exit 1
      ;;
    dispatching)
      now=$(date +%s)
      printf '%s' "$existing" | jq --argjson at "$now" '.state="uncertain" | .updated_at=$at | .reason="interrupted-dispatch"' \
        | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json" || exit 1
      fm_wake_append check "telegram-delivery-$RECEIPT_ID" "telegram-delivery-uncertain $RECEIPT_ID" || true
      echo "telegram send: interrupted delivery is uncertain; reconcile before any retry" >&2
      exit 3
      ;;
    prepared) ;;
    *) echo "telegram send: outbound receipt is malformed" >&2; exit 1 ;;
  esac
fi

REPLY_MESSAGE_ID=
if [ "$mode" = reply ]; then
  request=$(fm_private_read_file "$FMTG_STATE/inbox/$REQUEST_ID.json" 600) \
    || { echo "telegram send: request is unavailable or unsafe" >&2; exit 1; }
  REPLY_MESSAGE_ID=$(printf '%s' "$request" | jq -r '.telegram_message_id // empty')
  case "$REPLY_MESSAGE_ID" in ''|*[!0-9]*) echo "telegram send: request is malformed" >&2; exit 1 ;; esac
fi

if [ -n "$APPROVAL_ID" ] && { [ -e "$FMTG_STATE/approvals/$APPROVAL_ID.json" ] || [ -L "$FMTG_STATE/approvals/$APPROVAL_ID.json" ]; }; then
  approval=$(fm_private_read_file "$FMTG_STATE/approvals/$APPROVAL_ID.json" 600 2>/dev/null) \
    || { echo "telegram send: approval identity is unsafe" >&2; exit 1; }
  approval_state=$(printf '%s' "$approval" | jq -r '.status // empty')
  approval_receipt=$(printf '%s' "$approval" | jq -r '.receipt_id // empty')
  approval_request=$(printf '%s' "$approval" | jq -r '.request_id // empty')
  if [ "$approval_state" != preparing ] \
    || [ "$approval_receipt" != "$RECEIPT_ID" ] \
    || [ "$approval_request" != "$REQUEST_ID" ]; then
    echo "telegram send: approval identity already exists" >&2
    exit 1
  fi
  approval_reserved=1
fi

NOW=$(date +%s)
if [ -z "$existing_state" ]; then
  jq -n \
    --arg receipt_id "$RECEIPT_ID" --arg kind "$mode" --arg event_kind "$EVENT_KIND" \
    --arg request_id "$REQUEST_ID" --arg approval_id "$APPROVAL_ID" --arg source_hash "$SOURCE_HASH" \
    --argjson chunks "$CHUNKS_TOTAL" --argjson at "$NOW" '
      {schema:"firstmate.telegram-outbound.v1",receipt_id:$receipt_id,state:"prepared",kind:$kind,
       event_kind:(if $event_kind == "" then null else $event_kind end),request_id:$request_id,
       approval_id:(if $approval_id == "" then null else $approval_id end),source_sha256:$source_hash,
       chunks_total:$chunks,next_part:0,delivered_parts:[],attempts:0,created_at:$at,updated_at:$at}
    ' | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json" \
      || { echo "telegram send: could not prepare durable receipt" >&2; exit 1; }
fi

if [ -n "$APPROVAL_ID" ] && [ "$approval_reserved" -eq 0 ]; then
  jq -n --arg approval_id "$APPROVAL_ID" --arg receipt_id "$RECEIPT_ID" \
    --arg request_id "$REQUEST_ID" --argjson at "$NOW" '
      {schema:"firstmate.telegram-approval.v1",approval_id:$approval_id,receipt_id:$receipt_id,request_id:$request_id,status:"preparing",created_at:$at}
    ' | fmtg_json_publish "$FMTG_STATE/approvals" "$APPROVAL_ID.json" \
      || { echo "telegram send: could not reserve approval identity" >&2; exit 1; }
fi

PAYLOAD=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-send.XXXXXX") || exit 1
BODY=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-send-body.XXXXXX") || { rm -f -- "$PAYLOAD"; exit 1; }
PART_TEXT=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-send-text.XXXXXX") || { rm -f -- "$PAYLOAD" "$BODY"; exit 1; }
chmod 0600 "$PAYLOAD" "$BODY" "$PART_TEXT" || { rm -f -- "$PAYLOAD" "$BODY" "$PART_TEXT"; exit 1; }
# Reload immediately before API work so the token remains confined to this
# process and the owner-only curl config created by fmtg_api_call.
unset FMTG_TOKEN
fmtg_load_config || { echo "telegram send: bridge became disabled" >&2; exit 1; }

build_payload() { # <rich|plain> <part-index>
  local format=$1 part=$2 text
  if [ "$format" = rich ]; then
    text=$(printf '%s' "$SNAPSHOT" | jq -r --argjson part "$part" '.presentation.messages[$part].rich_text') || return 1
  else
    text=$(printf '%s' "$SNAPSHOT" | jq -r --argjson part "$part" '.presentation.messages[$part].plain_text') || return 1
  fi
  printf '%s' "$text" > "$PART_TEXT" || return 1
  if [ "$mode" = reply ]; then
    if [ "$format" = rich ]; then
      jq -n --arg chat "$FMTG_ALLOWED_CHAT_ID" --rawfile text "$PART_TEXT" --arg reply "$REPLY_MESSAGE_ID" '
        {chat_id:($chat|tonumber),text:$text,parse_mode:"HTML",protect_content:true,
         link_preview_options:{is_disabled:true},
         reply_parameters:{message_id:($reply|tonumber),allow_sending_without_reply:false}}
      ' > "$PAYLOAD"
    else
      jq -n --arg chat "$FMTG_ALLOWED_CHAT_ID" --rawfile text "$PART_TEXT" --arg reply "$REPLY_MESSAGE_ID" '
        {chat_id:($chat|tonumber),text:$text,protect_content:true,
         link_preview_options:{is_disabled:true},
         reply_parameters:{message_id:($reply|tonumber),allow_sending_without_reply:false}}
      ' > "$PAYLOAD"
    fi
  elif [ "$format" = rich ]; then
    jq -n --arg chat "$FMTG_ALLOWED_CHAT_ID" --rawfile text "$PART_TEXT" '
      {chat_id:($chat|tonumber),text:$text,parse_mode:"HTML",protect_content:true,link_preview_options:{is_disabled:true}}
    ' > "$PAYLOAD"
  else
    jq -n --arg chat "$FMTG_ALLOWED_CHAT_ID" --rawfile text "$PART_TEXT" '
      {chat_id:($chat|tonumber),text:$text,protect_content:true,link_preview_options:{is_disabled:true}}
    ' > "$PAYLOAD"
  fi
}

mark_dispatching() { # <part> <format> <attempt>
  local part=$1 format=$2 attempt=$3 current now
  current=$(fm_private_read_file "$RECEIPT_FILE" 600) || return 1
  now=$(date +%s)
  printf '%s' "$current" | jq --argjson at "$now" --argjson part "$part" \
    --arg format "$format" --argjson attempt "$attempt" '
      .state="dispatching" | .updated_at=$at | .current_part=$part | .current_format=$format |
      .attempts=((.attempts // 0) + 1) | .part_attempt=$attempt | del(.reason)
    ' | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json"
}

api_attempt() { # <part> <format>; sets PART_RESULT and message_id
  local part=$1 format=$2 attempt retry_after description
  PART_RESULT=uncertain
  message_id=
  build_payload "$format" "$part" || return 1
  attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    mark_dispatching "$part" "$format" "$attempt" || return 1
    if ! fmtg_api_call sendMessage "$PAYLOAD" "$BODY" "$FMTG_CURL_TIMEOUT"; then
      PART_RESULT=uncertain
      return 0
    fi
    if [ "$FMTG_API_HTTP" = 200 ]; then
      message_id=$(jq -r 'select(.ok == true) | .result.message_id // empty' "$BODY" 2>/dev/null)
      case "$message_id" in
        ''|*[!0-9]*) PART_RESULT=uncertain ;;
        *) PART_RESULT=sent ;;
      esac
      return 0
    fi
    if [ "$FMTG_API_HTTP" = 429 ] && [ "$attempt" -lt 3 ]; then
      retry_after=$(jq -r '.parameters.retry_after // empty' "$BODY" 2>/dev/null)
      case "$retry_after" in 1|2|3|4) sleep "$retry_after"; continue ;; esac
    fi
    if [ "$FMTG_API_HTTP" = 400 ] && [ "$format" = rich ]; then
      description=$(jq -r '.description // empty' "$BODY" 2>/dev/null)
      case "$description" in
        *"parse entities"*|*"unsupported start tag"*) PART_RESULT=plain-fallback ;;
        *) PART_RESULT=definite-failure ;;
      esac
    else
      case "$FMTG_API_HTTP" in 4??) PART_RESULT=definite-failure ;; *) PART_RESULT=uncertain ;; esac
    fi
    return 0
  done
}

OUTBOUND_LOCK="$FMTG_STATE/outbound.lock"
fm_lock_acquire_wait "$OUTBOUND_LOCK"
current=$(fm_private_read_file "$RECEIPT_FILE" 600) || { fm_lock_release "$OUTBOUND_LOCK"; exit 1; }
PART=$(printf '%s' "$current" | jq -r '.next_part // 0')
FINAL_STATE=sent
LAST_MESSAGE_ID=$(printf '%s' "$current" | jq -r '.telegram_message_id // empty')
while [ "$PART" -lt "$CHUNKS_TOTAL" ]; do
  now=$(date +%s)
  last_send=0
  if fm_private_file_valid "$FMTG_STATE/last-send" 600; then
    last_send=$(fm_private_read_file "$FMTG_STATE/last-send" 600 2>/dev/null || echo 0)
    case "$last_send" in ''|*[!0-9]*) last_send=0 ;; esac
  fi
  if [ "$now" -le "$last_send" ]; then sleep 1; fi

  api_attempt "$PART" rich || { FINAL_STATE=uncertain; break; }
  if [ "$PART_RESULT" = plain-fallback ]; then
    current=$(fm_private_read_file "$RECEIPT_FILE" 600) || { FINAL_STATE=uncertain; break; }
    printf '%s' "$current" | jq --argjson at "$(date +%s)" '.state="prepared" | .updated_at=$at | .rich_rejected=true | del(.current_format,.part_attempt)' \
      | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json" || { FINAL_STATE=uncertain; break; }
    api_attempt "$PART" plain || { FINAL_STATE=uncertain; break; }
  fi
  case "$PART_RESULT" in
    sent) ;;
    definite-failure) FINAL_STATE=definite-failure; break ;;
    *) FINAL_STATE=uncertain; break ;;
  esac

  LAST_MESSAGE_ID=$message_id
  next=$((PART + 1))
  current=$(fm_private_read_file "$RECEIPT_FILE" 600) || { FINAL_STATE=uncertain; break; }
  next_state=prepared
  printf '%s' "$current" | jq --argjson at "$(date +%s)" --argjson part "$PART" \
    --argjson next "$next" --arg message_id "$message_id" --arg format "${format:-rich}" --arg state "$next_state" '
      .state=$state | .updated_at=$at | .next_part=$next |
      .delivered_parts += [{part:$part,telegram_message_id:($message_id|tonumber),format:(.current_format // $format)}] |
      .telegram_message_id=($message_id|tonumber) | del(.current_part,.current_format,.part_attempt,.reason)
    ' | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json" \
      || { FINAL_STATE=uncertain; break; }
  printf '%s\n' "$(date +%s)" | fm_private_publish_stdin "$FMTG_STATE" last-send 600 || true
  PART=$next
done

current=$(fm_private_read_file "$RECEIPT_FILE" 600) || { fm_lock_release "$OUTBOUND_LOCK"; exit 1; }
now=$(date +%s)
case "$FINAL_STATE" in
  sent)
    printf '%s' "$current" | jq --argjson at "$now" --arg message_id "$LAST_MESSAGE_ID" '
      .state="sent" | .updated_at=$at | .sent_at=$at | .telegram_message_id=($message_id|tonumber) |
      del(.current_part,.current_format,.part_attempt,.reason)
    ' | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json" \
      || { fm_lock_release "$OUTBOUND_LOCK"; exit 1; }
    ;;
  definite-failure)
    printf '%s' "$current" | jq --argjson at "$now" --arg http "$FMTG_API_HTTP" '
      .state="definite-failure" | .updated_at=$at | .reason=("http-" + $http) |
      del(.current_part,.current_format,.part_attempt)
    ' | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json" || true
    ;;
  *)
    printf '%s' "$current" | jq --argjson at "$now" '
      .state="uncertain" | .updated_at=$at | .reason=(.reason // "ambiguous-response")
    ' | fmtg_json_publish "$FMTG_STATE/outbound" "$RECEIPT_ID.json" || true
    FINAL_STATE=uncertain
    ;;
esac
fm_lock_release "$OUTBOUND_LOCK"

case "$FINAL_STATE" in
  sent)
    sent_receipt=$(fm_private_read_file "$RECEIPT_FILE" 600) \
      || { echo "telegram send: sent receipt is unavailable" >&2; exit 1; }
    if ! finalize_sent_receipt "$sent_receipt"; then
      fmtg_error_once sent-receipt-finalization-failed >/dev/null || true
      echo "telegram send: delivery succeeded but durable finalization is incomplete" >&2
      exit 1
    fi
    rm -f -- "$SNAPSHOT_FILE" 2>/dev/null || true
    printf 'sent %s %s\n' "$RECEIPT_ID" "$LAST_MESSAGE_ID"
    exit 0
    ;;
  definite-failure)
    echo "telegram send: Telegram rejected delivery with HTTP $FMTG_API_HTTP" >&2
    exit 1
    ;;
  *)
    fm_wake_append check "telegram-delivery-$RECEIPT_ID" "telegram-delivery-uncertain $RECEIPT_ID" || true
    echo "telegram send: delivery outcome is uncertain; reconcile before any retry" >&2
    exit 3
    ;;
esac
