# shellcheck shell=bash
# Shared configuration, transport, and redaction for the Telegram bridge.
# Usage: . bin/fm-telegram-lib.sh   (requires bin/fm-env-lib.sh on the same path)
#
# The bridge gives the captain a second way in and out of a firstmate home:
# messages sent to the bot become ordinary captain notes, and firstmate can send
# short escalations back. bin/fm-procevent-telegram.sh owns the inbound half and
# bin/fm-telegram.sh owns the outbound half; this file owns only what both need.
#
# It defines:
#   fm_telegram_load        - resolve FM_TG_TOKEN, FM_TG_CHAT, FM_TG_NAME, FM_TG_API
#   fm_telegram_configured  - exit 0 when a bot token is present
#   fm_telegram_allowlisted - exit 0 when an allowed chat id is configured
#   fm_telegram_redact      - filter stdin, replacing the bot token with a marker
#   fm_telegram_api         - call one Telegram Bot API method, printing JSON
#   fm_telegram_send_text   - send one message to a chat id
#   fm_telegram_react       - react to one message with an emoji
#   fm_telegram_state_dir   - the home's durable bridge state directory
#   fm_telegram_write_atomic - replace a state file atomically
#
# OPT-IN AND INERT BY DEFAULT. Every capability here is gated on a non-empty
# TELEGRAM_BOT_TOKEN in the home's gitignored `.env`. With no token nothing
# resolves, nothing polls, and nothing is sent; callers check with
# fm_telegram_configured rather than discovering it from a failed request.
#
# THE TOKEN IS A CREDENTIAL AND NEVER LEAVES THIS PROCESS AS OUTPUT. It is read
# into a variable, spent as a URL path segment inside curl, and never printed,
# logged, or written to state. Because the token IS part of every request URL,
# curl's own diagnostics can quote it back; so every byte this file lets out of a
# request passes through fm_telegram_redact first. Callers that build their own
# message text must do the same before it reaches a status line or a note.
#
# CONFIGURATION, all from the home's gitignored `.env`:
#   TELEGRAM_BOT_TOKEN       required; the credential from @BotFather.
#   TELEGRAM_ALLOWED_CHAT_ID required for inbound; the one chat allowed to queue
#                            work, and the chat outbound messages are sent to.
#   TELEGRAM_BOT_NAME        optional; the bot's @handle, for operator messages.
# Each may be overridden by the matching environment variable, which is how the
# tests drive this without writing a credential file.
#
# FM_TELEGRAM_API_BASE overrides the API root (default https://api.telegram.org).
# It exists so the test suite can point the bridge at a local fake API and drive
# the real request/response path; it is not an operator setting.

fm_telegram_state_dir() { printf '%s\n' "${FM_TELEGRAM_STATE_OVERRIDE:-$FM_HOME/state}/telegram"; }

# Resolve configuration into FM_TG_* for the current process. Environment wins
# over `.env`, matching how Relay resolves its own pairing token.
fm_telegram_load() {
  local env_file="${FM_TELEGRAM_ENV_FILE:-$FM_HOME/.env}"
  if [ -n "${TELEGRAM_BOT_TOKEN+x}" ]; then
    FM_TG_TOKEN=${TELEGRAM_BOT_TOKEN-}
  else
    FM_TG_TOKEN=$(fm_env_get TELEGRAM_BOT_TOKEN "$env_file")
  fi
  if [ -n "${TELEGRAM_ALLOWED_CHAT_ID+x}" ]; then
    FM_TG_CHAT=${TELEGRAM_ALLOWED_CHAT_ID-}
  else
    FM_TG_CHAT=$(fm_env_get TELEGRAM_ALLOWED_CHAT_ID "$env_file")
  fi
  # Read here so every consumer resolves the handle the same way; only the
  # operator-facing status view actually prints it.
  # shellcheck disable=SC2034
  if [ -n "${TELEGRAM_BOT_NAME+x}" ]; then
    FM_TG_NAME=${TELEGRAM_BOT_NAME-}
  else
    FM_TG_NAME=$(fm_env_get TELEGRAM_BOT_NAME "$env_file")
  fi
  FM_TG_API=${FM_TELEGRAM_API_BASE:-https://api.telegram.org}

  # An allowed chat id is an identity the allowlist compares against, so anything
  # that is not a plain Telegram chat id is refused rather than half-matched. A
  # chat id is a signed integer; group ids are negative.
  case "$FM_TG_CHAT" in
    '') ;;
    -[0-9]* | [0-9]*)
      case "${FM_TG_CHAT#-}" in
        *[!0-9]*) FM_TG_CHAT_INVALID=1 ;;
        *) FM_TG_CHAT_INVALID=0 ;;
      esac
      ;;
    *) FM_TG_CHAT_INVALID=1 ;;
  esac
  : "${FM_TG_CHAT_INVALID:=0}"
}

fm_telegram_configured() { [ -n "${FM_TG_TOKEN-}" ]; }
fm_telegram_allowlisted() { [ -n "${FM_TG_CHAT-}" ] && [ "${FM_TG_CHAT_INVALID:-0}" -eq 0 ]; }

# Replace every occurrence of the bot token on stdin with a fixed marker. Used on
# ANY text derived from a request before it can reach a caller, a status line, a
# note, or a state file.
#
# Two deliberate choices, both load-bearing, both regression-tested. The match is
# awk index/substr rather than a regex, so a token containing regex
# metacharacters is still matched literally. And the token reaches awk through
# ENVIRON rather than `-v`, because `-v` processes backslash escapes in the value
# it is given: a token containing a backslash would arrive mangled, match
# nothing, and silently pass the credential straight through. Today's Telegram
# tokens carry no backslash, but a credential guard must not depend on that.
fm_telegram_redact() {
  if [ -z "${FM_TG_TOKEN-}" ]; then
    cat
    return 0
  fi
  FM_TG_REDACT_TOKEN="$FM_TG_TOKEN" awk '
    BEGIN { tok = ENVIRON["FM_TG_REDACT_TOKEN"] }
    {
      line = $0
      out = ""
      while ((i = index(line, tok)) > 0) {
        out = out substr(line, 1, i - 1) "<redacted>"
        line = substr(line, i + length(tok))
      }
      print out line
    }
  '
}

# Call one Bot API method and print its JSON response.
# fm_telegram_api <method> [curl-arg...]
#
# The token is passed through --url rather than being interpolated into a shell
# command, and stderr is folded into stdout through the redactor so a curl
# diagnostic that quotes the request URL cannot leak the credential. Returns
# curl's exit status; a transport failure prints an empty body, which callers
# treat as "no answer" rather than as a malformed reply.
fm_telegram_api() {
  local method=$1
  shift
  local rc=0 out
  out=$(curl -sS --max-time "${FM_TELEGRAM_HTTP_TIMEOUT:-120}" \
    --url "$FM_TG_API/bot$FM_TG_TOKEN/$method" "$@" 2>&1) || rc=$?
  printf '%s\n' "$out" | fm_telegram_redact
  return "$rc"
}

# Send one plain-text message. fm_telegram_send_text <chat-id> <text>
#
# The body is handed to curl as a JSON file rather than as a command string, so
# message text is never interpolated anywhere a shell or a URL parser reads it.
fm_telegram_send_text() {
  local chat=$1 text=$2 payload rc=0
  payload=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-send.XXXXXX") || return 1
  if ! jq -n --arg chat "$chat" --arg text "$text" \
    '{chat_id: $chat, text: $text, disable_web_page_preview: true}' >"$payload"; then
    rm -f "$payload"
    return 1
  fi
  fm_telegram_api sendMessage -X POST \
    -H 'Content-Type: application/json' --data-binary "@$payload" || rc=$?
  rm -f "$payload"
  return "$rc"
}

# React to one message with a single emoji.
# fm_telegram_react <chat-id> <message-id> [emoji]
#
# This is how the bridge confirms receipt. A reaction lands ON the captain's own
# message instead of adding another message to the chat, so the confirmation is
# visible without anything to read or dismiss.
#
# `message_id` is required to be an integer by the API, so it is converted with
# jq's tonumber and a non-numeric id fails the payload build rather than being
# sent as something the API would reject. Telegram also accepts only a fixed set
# of emoji as reactions; an unsupported one comes back as an API error, which
# the best-effort caller ignores like any other reaction failure.
fm_telegram_react() {
  local chat=$1 message_id=$2 emoji=${3:-👍} payload rc=0
  payload=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-react.XXXXXX") || return 1
  if ! jq -n --arg chat "$chat" --arg mid "$message_id" --arg emoji "$emoji" \
    '{chat_id: $chat, message_id: ($mid | tonumber),
      reaction: [{type: "emoji", emoji: $emoji}]}' >"$payload" 2>/dev/null; then
    rm -f "$payload"
    return 1
  fi
  fm_telegram_api setMessageReaction -X POST \
    -H 'Content-Type: application/json' --data-binary "@$payload" || rc=$?
  rm -f "$payload"
  return "$rc"
}

# Replace a small state file atomically, so a crash mid-write can never leave a
# half-written offset that would replay or skip messages.
fm_telegram_write_atomic() {  # <path> <content>
  local path=$1 content=$2 dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.tmp-XXXXXX") || return 1
  if ! printf '%s\n' "$content" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path"
}
