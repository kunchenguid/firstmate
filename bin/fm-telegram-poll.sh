#!/usr/bin/env bash
# One short-poll of Telegram Bot API getUpdates for inbound Stage-2 commands.
#
# Inert by default: a HARD no-op (exit 0, no output) unless Telegram mode is
# configured via non-empty FM_TELEGRAM_BOT_TOKEN + FM_TELEGRAM_CHAT_ID and the
# config/telegram-mode kill switch is not "off". The watcher invokes this trusted
# repository script only after state/telegram-watch.check.sh matches the expected
# byte-static identity shim.
#
# Contract: "output => wake firstmate, silence => keep sleeping".
#
# When on:
#   - getUpdates with persisted offset
#   - drop non-allowlisted senders and non-matching chats (audited, no reply);
#     those drops advance the offset so attackers cannot pin the backlog
#   - cap accepted authenticated messages per sweep (FMT_RATE_MAX); excess
#     authenticated updates are DEFERRED (not dropped): offset does not advance
#     past them, so the next sweep re-fetches (at-least-once for allowlisted
#     senders; captain decision key=telegram-rate-cap)
#   - stash accepted messages at state/telegram-inbox/<update_id>.json
#   - print one line per accepted update: "telegram-msg <update_id>"
#   - re-emit "telegram-msg <update_id>" for inbox files still pending from
#     earlier sweeps (e.g. rate-deferred by respond) so the drain retries
#     without requiring new inbound traffic
#   - permanently-unprocessable inbox files are quarantined by respond and
#     therefore never re-emitted; missing curl/jq emit a one-shot error and
#     skip pending re-wakes so a tool gap cannot storm the fleet every 30s
#   - HTTP 409 (second getUpdates consumer) surfaces as telegram-mode-error once
#
# Network is required only when configured; tests stub curl.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

fmt_load_config
# Hard no-op when off.
fmt_mode_enabled || exit 0

ERROR_FILE="$STATE/telegram-poll.error"
SWEEP_ERROR=
wakes=
INBOX="$STATE/telegram-inbox"

emit_error_once() {
  local msg=$1
  SWEEP_ERROR=1
  if fmx_private_artifact_file_valid "$STATE" "telegram-poll.error" 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE" "telegram-poll.error" 600 2>/dev/null || true
  fmt_audit_append poll error "$msg"
  printf 'telegram-mode-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_dir_device "$STATE" >/dev/null 2>&1 || return 0
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

queue_pending_wakes() {
  local f base uid
  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    base=${f##*/}
    uid=${base%.json}
    case "$uid" in
      ''|.*|*[!A-Za-z0-9._-]*) continue ;;
    esac
    fmx_single_link_file_valid "$f" || continue
    queue_wake "$uid"
  done
}

queue_wake() {
  local uid=$1
  case "$wakes" in
    *"telegram-msg ${uid}"$'\n'*) return 0 ;;
  esac
  wakes="${wakes}telegram-msg ${uid}"$'\n'
}

finish() {
  if [ -n "$wakes" ]; then
    printf '%s' "$wakes"
  fi
  exit 0
}

# Tool gaps are transient but must not re-wake every pending inbox file on
# every ~30s sweep. Emit a deduped telegram-mode-error and finish silently
# (no pending re-wakes) until curl/jq/node return; once present, pending files
# resume normal re-wake/retry. node is required by the quarantine helper, so
# without it permanently-bad files could never leave the live inbox.
command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; finish; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; finish; }
command -v node >/dev/null 2>&1 || { emit_error_once "missing node"; finish; }

queue_pending_wakes

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-poll.XXXXXX") || finish
trap 'rm -f "$BODY_FILE"' EXIT

offset=$(fmt_offset_get)
# timeout=0 short poll keeps us inside FM_CHECK_TIMEOUT.
url="$FMT_API/bot${FMT_TOKEN}/getUpdates?timeout=0&allowed_updates=%5B%22message%22%5D"
if [ -n "$offset" ]; then
  url="${url}&offset=${offset}"
fi
URL_FILE=$(fmt_curl_url_config "$url") || finish
trap 'rm -f "$BODY_FILE" "$URL_FILE"' EXIT

code=$(curl -m 8 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H 'Accept: application/json' \
  --config "$URL_FILE" 2>/dev/null) || finish

case "$code" in
  200) ;;
  409)
    emit_error_once "getUpdates HTTP 409 conflict - another consumer may hold this bot token; revoke at BotFather if unexpected"
    finish
    ;;
  401|403)
    emit_error_once "getUpdates HTTP $code - check bot token"
    finish
    ;;
  *)
    # Transient errors stay silent (next sweep retries).
    finish
    ;;
esac

[ -s "$BODY_FILE" ] || { clear_error; finish; }

ok=$(jq -r '.ok // false' "$BODY_FILE" 2>/dev/null) || ok=false
if [ "$ok" != true ] && [ "$ok" != "true" ]; then
  # API-level failure with 200 is rare; treat as soft error.
  finish
fi

# Process updates in ascending update_id order.
# last_confirmed = highest update_id we may acknowledge to Telegram (offset =
# last_confirmed+1). Auth drops and successful accepts advance it. Rate-capped
# authenticated messages are deferred: we stop confirming and leave the offset
# before them so the next sweep re-fetches (DEFER, never drop).
last_confirmed=
processed=0
deferred=

confirm_uid() {
  local uid=$1
  if [ -z "$last_confirmed" ] || [ "$uid" -gt "$last_confirmed" ] 2>/dev/null; then
    last_confirmed=$uid
  fi
}

while IFS= read -r update_json; do
  [ -n "$update_json" ] || continue
  uid=$(printf '%s' "$update_json" | jq -r '.update_id // empty' 2>/dev/null) || continue
  case "$uid" in
    ''|*[!0-9]*) continue ;;
  esac

  # Once an authenticated update is deferred for rate, do not confirm anything
  # later in this sweep (Telegram delivers in order; later ids stay pending).
  if [ -n "$deferred" ]; then
    continue
  fi

  msg=$(printf '%s' "$update_json" | jq -c '.message // empty' 2>/dev/null) || msg=
  [ -n "$msg" ] || {
    fmt_audit_append inbound dropped-no-message "update_id=$uid"
    confirm_uid "$uid"
    continue
  }

  chat_id=$(printf '%s' "$msg" | jq -r '.chat.id // empty' 2>/dev/null) || chat_id=
  from_id=$(printf '%s' "$msg" | jq -r '.from.id // empty' 2>/dev/null) || from_id=
  text=$(printf '%s' "$msg" | jq -r '(.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' 2>/dev/null) || text=
  msg_date=$(printf '%s' "$msg" | jq -r '.date // empty' 2>/dev/null) || msg_date=
  chat_type=$(printf '%s' "$msg" | jq -r '.chat.type // empty' 2>/dev/null) || chat_type=

  # Direct (1:1) chat only; never groups/channels. Auth rejects advance offset
  # so unauthenticated traffic cannot pin the backlog forever.
  if [ "$chat_type" != "private" ]; then
    fmt_audit_append inbound dropped-auth "update_id=$uid chat_type=$chat_type chat=$chat_id from=$from_id"
    confirm_uid "$uid"
    continue
  fi
  if ! fmt_chat_allowed "$chat_id"; then
    fmt_audit_append inbound dropped-auth "update_id=$uid chat=$chat_id from=$from_id"
    confirm_uid "$uid"
    continue
  fi
  if ! fmt_sender_allowed "$from_id"; then
    fmt_audit_append inbound dropped-auth "update_id=$uid chat=$chat_id from=$from_id"
    confirm_uid "$uid"
    continue
  fi
  if [ -z "$text" ]; then
    fmt_audit_append inbound dropped-empty "update_id=$uid from=$from_id"
    confirm_uid "$uid"
    continue
  fi

  # Authenticated, non-empty: subject to per-sweep rate cap. Over-cap DEFERs.
  if [ "$processed" -ge "${FMT_RATE_MAX:-10}" ]; then
    deferred=$uid
    fmt_audit_append inbound deferred "update_id=$uid reason=rate-cap"
    # Do not confirm this update_id; next sweep re-fetches from here.
    continue
  fi

  # Inbox filename must be a safe slug (update_id is numeric, still validate).
  case "$uid" in
    ''|.*|*[!A-Za-z0-9._-]*) continue ;;
  esac

  INBOX="$STATE/telegram-inbox"
  # Stash a normalized envelope for respond.
  stash=$(jq -cn \
    --argjson update "$update_json" \
    --arg text "$text" \
    --arg from "$from_id" \
    --arg chat "$chat_id" \
    --arg date "$msg_date" \
    --arg uid "$uid" \
    '{
      update_id: ($uid|tonumber),
      text: $text,
      from_id: $from,
      chat_id: $chat,
      date: (if $date == "" then null else ($date|tonumber) end),
      raw: $update
    }' 2>/dev/null) || stash=

  if [ -z "$stash" ]; then
    emit_error_once "cannot build inbox payload"
    # Build failure is not a permanent drop; leave unconfirmed for retry.
    deferred=$uid
    continue
  fi

  if ! printf '%s\n' "$stash" | fmx_private_artifact_publish_stdin "$INBOX" "$uid.json" 600; then
    emit_error_once "cannot write inbox"
    deferred=$uid
    continue
  fi

  processed=$((processed + 1))
  confirm_uid "$uid"
  first=$(printf '%s\n' "$text" | head -c 80)
  fmt_audit_append inbound accepted "update_id=$uid from=$from_id text=$first"
  queue_wake "$uid"
done < <(jq -c '.result // [] | .[]' "$BODY_FILE" 2>/dev/null)

# Confirm only through last_confirmed. Deferred authenticated updates keep the
# offset before them so getUpdates re-serves them next sweep.
if [ -n "$last_confirmed" ]; then
  next=$((last_confirmed + 1))
  fmt_offset_set "$next" || emit_error_once "cannot persist offset"
fi

# Any healthy 200 sweep without a new error clears the stale marker so the
# next distinct incident (e.g. a fresh 409 conflict) surfaces again.
if [ -z "$SWEEP_ERROR" ]; then
  clear_error
fi
finish
