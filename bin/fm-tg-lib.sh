#!/usr/bin/env bash
# Shared config resolution and Telegram API helpers for the Telegram bridge
# (fm-tg-poll.sh and fm-tg-reply.sh). Telegram mode is opt-in: a user drops
# a non-empty FMTG_BOT_TOKEN into the firstmate home's .env. Until then
# polling is a hard no-op; replies can still run in FMTG_DRY_RUN preview
# mode without a token.
#
# This file is sourced, never executed. It defines:
#   fmtg_env_get <key> <file>   - read one KEY=VALUE from a .env-style file
#   fmtg_load_config            - resolve FMTG_TOKEN, FMTG_ALLOWED, FMTG_DRY
#   fmtg_api_call <method> [json_body_file] - call Telegram Bot API
#   fmtg_send_message <chat_id> <text-file> - send a message via sendMessage
#   fmtg_get_updates <offset>   - call getUpdates with long polling
#   fmtg_meta_get <meta> <key>  - read one key=value line from a task meta file
#   fmtg_meta_link_set <meta> <chat_id> <message_id> <epoch> [followups]
#   fmtg_meta_followups_set <meta> <n> - rewrite just the follow-up counter
#   fmtg_meta_link_clear <meta> - remove the Telegram link entirely
# Callers must have FM_HOME set before calling fmtg_load_config.

fmtg_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

fmtg_load_config() {
  local env_file="$FM_HOME/.env" dry
  if [ -n "${FMTG_BOT_TOKEN+x}" ]; then
    FMTG_TOKEN=${FMTG_BOT_TOKEN-}
  else
    FMTG_TOKEN=$(fmtg_env_get FMTG_BOT_TOKEN "$env_file")
  fi
  if [ -n "${FMTG_ALLOWED_USERS+x}" ]; then
    FMTG_ALLOWED=${FMTG_ALLOWED_USERS-}
  else
    FMTG_ALLOWED=$(fmtg_env_get FMTG_ALLOWED_USERS "$env_file")
  fi
  if [ -n "${FMTG_DRY_RUN+x}" ]; then
    dry=${FMTG_DRY_RUN-}
  else
    dry=$(fmtg_env_get FMTG_DRY_RUN "$env_file")
  fi
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) FMTG_DRY="" ;;
    *) FMTG_DRY=1 ;;
  esac
}

# fmtg_api_call <method> [json_body_file]: call Telegram Bot API.
# If json_body_file is provided, sends POST with JSON body.
# Otherwise sends GET. FMTG_RESPONSE_FILE must be set by caller.
# Prints HTTP code to stdout; response body to FMTG_RESPONSE_FILE.
fmtg_api_call() {
  local method=$1 body_file=${2:-} code rc auth_header
  command -v curl >/dev/null 2>&1 || return 127
  [ -n "$FMTG_TOKEN" ] || return 3
  [ -n "$FMTG_RESPONSE_FILE" ] || return 2

  auth_header=$(mktemp "${TMPDIR:-/tmp}/fm-tg-auth.XXXXXX") || return 1
  printf 'Authorization: Bearer %s\n' "$FMTG_TOKEN" > "$auth_header" || { rm -f "$auth_header"; return 1; }

  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    code=$(curl -m 10 -s -o "$FMTG_RESPONSE_FILE" -w '%{http_code}' \
      -X POST \
      -H "@$auth_header" \
      -H 'Content-Type: application/json' \
      --data-binary "@$body_file" \
      "https://api.telegram.org/bot${FMTG_TOKEN}/${method}" 2>/dev/null)
  else
    code=$(curl -m 10 -s -o "$FMTG_RESPONSE_FILE" -w '%{http_code}' \
      -H "@$auth_header" \
      "https://api.telegram.org/bot${FMTG_TOKEN}/${method}" 2>/dev/null)
  fi
  rc=$?
  rm -f "$auth_header"
  [ "$rc" = 0 ] || return 4
  printf '%s\n' "$code"
}

# fmtg_send_message <chat_id> <text-file>: send a text message.
# On success prints JSON response; on failure exits non-zero.
fmtg_send_message() {
  local chat_id=$1 text_file=$2 payload_file code text_escaped
  [ -n "$chat_id" ] || return 2
  [ -f "$text_file" ] || return 2

  text_escaped=$(jq -Rs '.' "$text_file") || return 1
  payload_file=$(mktemp "${TMPDIR:-/tmp}/fm-tg-msg.XXXXXX") || return 1
  jq -cn --arg chat_id "$chat_id" --argjson text "$text_escaped" \
    '{chat_id:$chat_id,text:$text}' > "$payload_file" || { rm -f "$payload_file"; return 1; }

  FMTG_RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-tg-resp.XXXXXX") || { rm -f "$payload_file"; return 1; }
  code=$(fmtg_api_call sendMessage "$payload_file")
  local rc=$?
  rm -f "$payload_file"

  if [ "$rc" -ne 0 ]; then
    rm -f "$FMTG_RESPONSE_FILE"
    echo "fm-tg-lib: sendMessage call failed (transport error)" >&2
    return 1
  fi
  case "$code" in
    2[0-9][0-9]) cat "$FMTG_RESPONSE_FILE"; rm -f "$FMTG_RESPONSE_FILE"; return 0 ;;
    *)
      echo "fm-tg-lib: sendMessage returned HTTP $code" >&2
      jq -r '.description // "unknown error"' "$FMTG_RESPONSE_FILE" 2>/dev/null >&2 || true
      rm -f "$FMTG_RESPONSE_FILE"
      return 1
      ;;
  esac
}

# fmtg_get_updates <offset>: call getUpdates with long polling.
# offset is the last confirmed update_id. Returns JSON on stdout.
# FMTG_RESPONSE_FILE must be set by caller.
fmtg_get_updates() {
  local offset=$1 code timeout=25
  code=$(fmtg_api_call "getUpdates?offset=${offset}&timeout=${timeout}&allowed_updates=%5B%22message%22%5D")
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$FMTG_RESPONSE_FILE" 2>/dev/null || true
    return 1
  fi
  case "$code" in
    2[0-9][0-9]) cat "$FMTG_RESPONSE_FILE"; rm -f "$FMTG_RESPONSE_FILE"; return 0 ;;
    409)
      echo "fm-tg-lib: getUpdates returned HTTP 409 - webhook may be active" >&2
      rm -f "$FMTG_RESPONSE_FILE"
      return 1
      ;;
    *)
      echo "fm-tg-lib: getUpdates returned HTTP $code" >&2
      rm -f "$FMTG_RESPONSE_FILE"
      return 1
      ;;
  esac
}

# --- task <-> Telegram message link (state/<id>.meta backed) ---

fmtg_meta_get() {
  local meta=$1 key=$2 line
  [ -f "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}"
}

fmtg_meta_tmp() {
  local meta=$1 dir base
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  [ -d "$dir" ] || return 1
  mktemp "$dir/.${base}.fm-tg.XXXXXX"
}

fmtg_meta_link_set() {
  local meta=$1 chat_id=$2 message_id=$3 ts=$4 followups=${5:-0} tmp
  [ -f "$meta" ] || return 1
  tmp=$(fmtg_meta_tmp "$meta") || return 1
  if ! { grep -vE '^tg_chat=|^tg_message=|^tg_followups=|^tg_link_ts=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf 'tg_chat=%s\n' "$chat_id" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'tg_message=%s\n' "$message_id" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'tg_followups=%s\n' "$followups" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'tg_link_ts=%s\n' "$ts" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

fmtg_meta_followups_set() {
  local meta=$1 n=$2 tmp
  [ -f "$meta" ] || return 1
  tmp=$(fmtg_meta_tmp "$meta") || return 1
  if ! { grep -vE '^tg_followups=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf 'tg_followups=%s\n' "$n" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

fmtg_meta_link_clear() {
  local meta=$1 tmp
  [ -f "$meta" ] || return 0
  tmp=$(fmtg_meta_tmp "$meta") || return 1
  if ! { grep -vE '^tg_chat=|^tg_message=|^tg_followups=|^tg_link_ts=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}
