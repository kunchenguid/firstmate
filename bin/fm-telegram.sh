#!/usr/bin/env bash
# fm-telegram.sh - private, notification-only Telegram transport for away mode.
#
# Usage:
#   fm-telegram.sh setup
#   fm-telegram.sh ready
#   fm-telegram.sh notify-wake       # reads one watcher event from stdin
#   fm-telegram.sh notify-result <quota-result-file>
#   fm-telegram.sh notify-wedge
#
# setup reads the bot token from config/telegram-bot-token and the chat binding
# from config/telegram-chat-id. Both files must be regular, owner-only 0600
# files under an owner-only 0700 config directory. When the chat file is absent,
# setup reads one chat id from stdin and stores it with those permissions. It
# verifies the bot with getMe and the binding with getChat; it never polls
# getUpdates, handles inbound commands, or sends a setup message.
#
# send accepts only fixed event names and never accepts caller-supplied text.
# It sends only while a confirmed away posture records reach_channels: telegram.
# notify-wake maps an actionable watcher event to one fixed event name and
# ignores routine reasons. notify-result handles only a quota adapter result and
# sends the fixed Codex weekly-quota notification for low or exhausted outcomes.
#
# The Telegram bot token is placed only in curl's private configuration stdin,
# never in process arguments, output, logs, tracked files, or notification text.
# HTTP calls are short and bounded. A failed call gets one in-call retry and
# remains best-effort without a durable retry queue. Successful event keys are
# recorded privately per away session and event identity so replaying the same
# watcher event does not duplicate notifications.
# FM_TELEGRAM_TRANSPORT is a test-only transport seam: its command receives the
# method, request-file path, and response-file path, never the bot token.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TOKEN_FILE="$CONFIG/telegram-bot-token"
CHAT_FILE="$CONFIG/telegram-chat-id"
NOTIFIED_FILE="$STATE/.telegram-notifications"
NOTIFY_LOCK="$STATE/.telegram-notifications.lock"
POSTURE_LOCK="$STATE/.cursor-park-owner.lock"
TELEGRAM_NOTIFIED_KEEP=64
TELEGRAM_SEND_ATTEMPTS=2

TELEGRAM_TOKEN=
export -n TELEGRAM_TOKEN 2>/dev/null || true

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

TELEGRAM_CHAT_ID=
TELEGRAM_SESSION=
TELEGRAM_SETUP_REQUEST_ME=
TELEGRAM_SETUP_REQUEST_CHAT=
TELEGRAM_SETUP_RESPONSE_ME=
TELEGRAM_SETUP_RESPONSE_CHAT=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

die() { printf 'fm-telegram: %s\n' "$1" >&2; exit 1; }

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

file_links() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

file_owner() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

private_directory_valid() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(file_mode "$1")" = 700 ] || return 1
  [ "$(file_owner "$1")" = "$(id -u)" ]
}

private_file_valid() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(file_mode "$file")" = 600 ] || return 1
  [ "$(file_links "$file")" = 1 ] || return 1
  [ "$(file_owner "$file")" = "$(id -u)" ]
}

# Read one line without ever printing it. The command-substitution sentinel
# preserves a final newline distinction while rejecting additional lines.
private_value() {
  local file=$1 value
  private_file_valid "$file" || return 1
  value=$(awk 'NR == 1 { first=$0; next } { bad=1 } END { if (bad) exit 1; printf "%s", first }' "$file") || return 1
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

telegram_token_load() {
  local value
  TELEGRAM_TOKEN=
  value=$(private_value "$TOKEN_FILE") || return 1
  case "$value" in
    [0-9]*:[A-Za-z0-9_-]*) ;;
    *) TELEGRAM_TOKEN=; return 1 ;;
  esac
  TELEGRAM_TOKEN=$value
}

telegram_chat_load() {
  local value
  TELEGRAM_CHAT_ID=
  value=$(private_value "$CHAT_FILE") || return 1
  case "$value" in
    [0-9]*) ;;
    *) TELEGRAM_CHAT_ID=; return 1 ;;
  esac
  [ "$value" != 0 ] || { TELEGRAM_CHAT_ID=; return 1; }
  TELEGRAM_CHAT_ID=$value
}

telegram_config_ready() {
  telegram_state_prepare || return 1
  private_directory_valid "$CONFIG" || return 1
  telegram_token_load || return 1
  telegram_chat_load || return 1
}

telegram_state_prepare() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  chmod 700 "$STATE" 2>/dev/null || return 1
  private_directory_valid "$STATE"
}

# Make a new configuration directory only. An existing directory is never
# relaxed or replaced; its owner-only mode is part of the secret boundary.
telegram_config_prepare() {
  if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    private_directory_valid "$CONFIG" || return 1
  else
    (umask 077; mkdir -p "$CONFIG") || return 1
    chmod 700 "$CONFIG" || return 1
  fi
}

write_chat_atomic() {
  local chat=$1 tmp
  case "$chat" in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  [ "$chat" != 0 ] || return 1
  tmp=$(mktemp "$CHAT_FILE.XXXXXX") || return 1
  if ! chmod 600 "$tmp" || ! printf '%s\n' "$chat" > "$tmp" || ! mv -f "$tmp" "$CHAT_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  private_file_valid "$CHAT_FILE"
}

json_ok() {
  local response=$1
  jq -e '.ok == true' "$response" >/dev/null 2>&1
}

json_result_object() {
  local response=$1
  jq -e '.ok == true and (.result | type) == "object"' "$response" >/dev/null 2>&1
}

json_private_chat() {
  local response=$1
  jq -e '.ok == true and .result.type == "private"' "$response" >/dev/null 2>&1
}

# telegram_api <getMe|getChat|sendMessage> <request-json> <response-file>
# The token is deliberately supplied through stdin to curl's config parser.
# The request and response paths contain no secret material and may be argv.
telegram_api() {
  local method=$1 request=$2 response=$3 timeout=${FM_TELEGRAM_TIMEOUT:-5} connect=${FM_TELEGRAM_CONNECT_TIMEOUT:-2}
  case "$method" in getMe|getChat|sendMessage) ;; *) return 2 ;; esac
  case "$timeout" in ''|*[!0-9]*|0) timeout=5 ;; esac
  case "$connect" in ''|*[!0-9]*|0) connect=2 ;; esac
  [ "$timeout" -le 15 ] || timeout=5
  [ "$connect" -le "$timeout" ] || connect=2
  [ -n "$TELEGRAM_TOKEN" ] || telegram_token_load || return 1
  : > "$response" || return 1
  if [ -n "${FM_TELEGRAM_TRANSPORT:-}" ]; then
    "$FM_TELEGRAM_TRANSPORT" "$method" "$request" "$response" >/dev/null 2>&1 || return 1
    [ -s "$response" ] || return 1
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 1
  {
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TELEGRAM_TOKEN" "$method"
    printf 'request = "POST"\n'
    printf 'header = "Content-Type: application/json"\n'
  } | curl --config - --connect-timeout "$connect" --max-time "$timeout" \
    --data-binary "@$request" --output "$response" >/dev/null 2>&1
}

telegram_setup_cleanup() {
  rm -f -- "$TELEGRAM_SETUP_REQUEST_ME" "$TELEGRAM_SETUP_REQUEST_CHAT" \
    "$TELEGRAM_SETUP_RESPONSE_ME" "$TELEGRAM_SETUP_RESPONSE_CHAT"
}

telegram_setup() {
  local chat
  telegram_state_prepare || die "state directory must be an owner-only 0700 directory: $STATE"
  telegram_config_prepare || die "config directory must be an owner-only 0700 directory: $CONFIG"
  telegram_token_load || die "bot token is missing or invalid; store it in the private local file config/telegram-bot-token"
  if [ -e "$CHAT_FILE" ] || [ -L "$CHAT_FILE" ]; then
    private_file_valid "$CHAT_FILE" || die "chat binding must be an owner-only 0600 regular file: $CHAT_FILE"
    telegram_chat_load || die "chat binding must be a non-zero numeric Telegram chat id"
  else
    if [ -t 0 ]; then
      printf 'Telegram chat id: ' >&2
    fi
    IFS= read -r chat || true
    [ -n "${chat:-}" ] || die "no chat id was provided; pipe one value to setup or create config/telegram-chat-id"
    if IFS= read -r _extra; then
      die "setup accepts exactly one chat id"
    fi
    write_chat_atomic "$chat" || die "could not securely store the Telegram chat binding"
    telegram_chat_load || die "stored chat binding could not be read safely"
  fi
  TELEGRAM_SETUP_REQUEST_ME=$(mktemp "$STATE/.telegram-setup.XXXXXX") || die "could not create a private API request file"
  TELEGRAM_SETUP_REQUEST_CHAT=$(mktemp "$STATE/.telegram-setup.XXXXXX") || { telegram_setup_cleanup; die "could not create a private API request file"; }
  TELEGRAM_SETUP_RESPONSE_ME=$(mktemp "$STATE/.telegram-setup.XXXXXX") || { telegram_setup_cleanup; die "could not create a private API response file"; }
  TELEGRAM_SETUP_RESPONSE_CHAT=$(mktemp "$STATE/.telegram-setup.XXXXXX") || { telegram_setup_cleanup; die "could not create a private API response file"; }
  chmod 600 "$TELEGRAM_SETUP_REQUEST_ME" "$TELEGRAM_SETUP_REQUEST_CHAT" "$TELEGRAM_SETUP_RESPONSE_ME" "$TELEGRAM_SETUP_RESPONSE_CHAT" || { telegram_setup_cleanup; die "could not secure API files"; }
  trap telegram_setup_cleanup EXIT
  printf '{}\n' > "$TELEGRAM_SETUP_REQUEST_ME"
  telegram_api getMe "$TELEGRAM_SETUP_REQUEST_ME" "$TELEGRAM_SETUP_RESPONSE_ME" || die "Telegram API verification failed"
  json_result_object "$TELEGRAM_SETUP_RESPONSE_ME" || die "Telegram API returned an invalid bot verification response"
  jq -cn --arg chat "$TELEGRAM_CHAT_ID" '{chat_id:$chat}' > "$TELEGRAM_SETUP_REQUEST_CHAT" || die "could not compose the private chat verification request"
  telegram_api getChat "$TELEGRAM_SETUP_REQUEST_CHAT" "$TELEGRAM_SETUP_RESPONSE_CHAT" || die "Telegram chat verification failed"
  json_result_object "$TELEGRAM_SETUP_RESPONSE_CHAT" || die "Telegram API returned an invalid chat verification response"
  json_private_chat "$TELEGRAM_SETUP_RESPONSE_CHAT" || die "Telegram chat verification did not identify a private chat"
  trap - EXIT
  telegram_setup_cleanup
  printf 'Telegram away notifications are configured and verified.\n'
}

telegram_away_session_load() {
  local record="$STATE/.afk-contract" contract="$FM_ROOT/bin/fm-afk-contract.sh"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  [ -x "$contract" ] || return 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$contract" validate --path "$record" >/dev/null 2>&1 || return 1
  [ "$(awk -F': ' '$1 == "reach_channels" { print $2; exit }' "$record" 2>/dev/null)" = telegram ] || return 1
  [ -n "$(awk -F': ' '$1 == "confirmed" { print $2; exit }' "$record" 2>/dev/null)" ] || return 1
  TELEGRAM_SESSION=$(awk -F': ' '$1 == "entered_epoch" { print $2; exit }' "$record" 2>/dev/null)
  case "$TELEGRAM_SESSION" in ''|*[!0-9]*) TELEGRAM_SESSION=; return 1 ;; esac
  # Pi has no legacy daemon flag; a present contract is away mode there. A
  # present quiet flag is explicitly not the captain's away posture.
  if [ -f "$STATE/.afk" ] && [ "$(sed -n '1p' "$STATE/.afk" 2>/dev/null)" = quiet ]; then
    return 1
  fi
}

telegram_event_text() {
  case "$1" in
    boundary) printf 'Firstmate away notification: supervision reached a captain-facing boundary.' ;;
    error)    printf 'Firstmate away notification: supervision reported an error that needs attention.' ;;
    stalled)  printf 'Firstmate away notification: supervision may be stalled and needs attention.' ;;
    wedge)    printf 'Firstmate away notification: away supervision notification delivery is wedged.' ;;
    quota)    printf 'Firstmate away notification: Codex weekly quota is at or below 70%% remaining.' ;;
    *) return 1 ;;
  esac
}

telegram_identity_digest() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

telegram_event_key() {
  local digest
  digest=$(telegram_identity_digest "$2") || return 1
  printf 'fm-telegram-v1:%s:%s:%s' "$TELEGRAM_SESSION" "$1" "$digest"
}

telegram_notified() {
  local key=$1 file=${2:-$NOTIFIED_FILE}
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  grep -F -x -- "$key" "$file" >/dev/null 2>&1
}

telegram_record_success() {
  local key=$1 file=${2:-$NOTIFIED_FILE} tmp
  if [ -e "$file" ] || [ -L "$file" ]; then
    private_file_valid "$file" || return 1
  fi
  tmp=$(mktemp "$file.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -f "$file" ] && ! cat "$file" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$key" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  # Retaining only a small tail keeps this private dedupe journal bounded.
  tail -n "$TELEGRAM_NOTIFIED_KEEP" "$tmp" > "${tmp}.tail" || { rm -f -- "$tmp" "${tmp}.tail"; return 1; }
  mv -f -- "${tmp}.tail" "$tmp" || { rm -f -- "$tmp" "${tmp}.tail"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  private_file_valid "$file"
}

# Send one notification text under the shared bounded lock. Callers supply only
# local aggregate text or fixed text; no caller can supply a watcher reason.
telegram_send_text() {
  local key=$1 text=$2 journal=${3:-$NOTIFIED_FILE} request response lock_result attempt
  mkdir -p "$STATE" || return 1
  if ! fm_lock_acquire_wait_bounded "$NOTIFY_LOCK" 2; then
    # Distinguish contention from a successful no-op for best-effort callers.
    return 75
  fi
  lock_result=0
  trap 'fm_lock_release "$NOTIFY_LOCK" || true' RETURN
  if telegram_notified "$key" "$journal"; then
    trap - RETURN
    fm_lock_release "$NOTIFY_LOCK" || true
    return 0
  fi
  request=$(mktemp "$STATE/.telegram-request.XXXXXX") || lock_result=1
  response=$(mktemp "$STATE/.telegram-response.XXXXXX") || lock_result=1
  if [ "$lock_result" -eq 0 ]; then
    chmod 600 "$request" "$response" || lock_result=1
  fi
  if [ "$lock_result" -eq 0 ]; then
    jq -cn --arg chat "$TELEGRAM_CHAT_ID" --arg text "$text" \
      '{chat_id:$chat,text:$text,disable_notification:false}' > "$request" || lock_result=1
  fi
  if [ "$lock_result" -eq 0 ]; then
    attempt=0
    while [ "$attempt" -lt "$TELEGRAM_SEND_ATTEMPTS" ]; do
      attempt=$((attempt + 1))
      if telegram_api sendMessage "$request" "$response" && json_ok "$response"; then
        lock_result=0
        break
      fi
      lock_result=1
    done
  fi
  if [ "$lock_result" -eq 0 ] && ! telegram_record_success "$key" "$journal"; then
    lock_result=1
  fi
  rm -f -- "${request:-}" "${response:-}"
  trap - RETURN
  fm_lock_release "$NOTIFY_LOCK" || true
  return "$lock_result"
}

telegram_posture_lock_acquire() {
  fm_afk_contract_lock_hold "$STATE" || return 1
  if ! fm_lock_acquire_wait_bounded "$POSTURE_LOCK" 2; then
    fm_afk_contract_lock_release || true
    return 1
  fi
}

telegram_posture_lock_release() {
  local rc=0
  fm_lock_release "$POSTURE_LOCK" || rc=1
  fm_afk_contract_lock_release || rc=1
  return "$rc"
}

# Send one fixed event. Disabled/unconfigured homes are a successful no-op for
# watcher callers; malformed configured files are reported to direct callers.
telegram_send_kind() {
  local kind=$1 identity=${2:-$1} text='' rc=0
  telegram_posture_lock_acquire || return 1
  if telegram_away_session_load; then
    telegram_state_prepare || rc=1
    if [ "$rc" -eq 0 ]; then telegram_config_ready || rc=1; fi
    if [ "$rc" -eq 0 ]; then text=$(telegram_event_text "$kind") || rc=2; fi
    if [ "$rc" -eq 0 ]; then
      telegram_send_text "$(telegram_event_key "$kind" "$identity")" "$text" || rc=$?
    fi
  fi
  telegram_posture_lock_release || rc=1
  return "$rc"
}

telegram_kind_for_wake() {
  local reason=$1
  case "$reason" in
    heartbeat|heartbeat:*) return 1 ;;
    stale:*) printf 'stalled\n' ;;
    check:*afk-codex-weekly*) return 1 ;;
    check:*) printf 'error\n' ;;
    signal:*) return 1 ;;
    needs-decision:*) printf 'error\n' ;;
    *) printf 'error\n' ;;
  esac
}

telegram_notify_wake() {
  local reason hinted_kind identity kind
  IFS= read -r reason || true
  IFS= read -r hinted_kind || true
  IFS= read -r identity || true
  [ -n "${reason:-}" ] || return 0
  case "$reason" in
    signal:*)
      case "$hinted_kind" in boundary|error) kind=$hinted_kind ;; *) return 0 ;; esac
      ;;
    *) kind=$(telegram_kind_for_wake "$reason" 2>/dev/null) || return 0 ;;
  esac
  [ -n "${identity:-}" ] || identity=$reason
  telegram_send_kind "$kind" "$identity"
}

telegram_notify_result() {
  local result=$1 source status
  [ -f "$result" ] && [ ! -L "$result" ] || return 0
  source=$(awk -F': ' '$1 == "quota" { print $2; exit }' "$result" 2>/dev/null)
  case "$source" in afk-codex-weekly) ;; *) return 0 ;; esac
  status=$(awk -F': ' '$1 == "status" { print $2; exit }' "$result" 2>/dev/null)
  case "$status" in
    low|exhausted) telegram_send_kind quota ;;
    error) telegram_send_kind error ;;
    *) return 0 ;;
  esac
}

case "${1:-}" in
  setup) [ "$#" -eq 1 ] || usage; telegram_setup ;;
  ready) [ "$#" -eq 1 ] || usage; telegram_config_ready ;;
  notify-wake) [ "$#" -eq 1 ] || usage; telegram_notify_wake ;;
  notify-result) [ "$#" -eq 2 ] || usage; telegram_notify_result "$2" ;;
  notify-wedge) [ "$#" -eq 1 ] || usage; telegram_send_kind wedge ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
