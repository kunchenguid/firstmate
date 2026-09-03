#!/usr/bin/env bash
# fm-telegram.sh - the outbound half of the Telegram bridge.
#
# Usage:
#   fm-telegram.sh send <text>...          | fm-telegram.sh send -   (body on stdin)
#   fm-telegram.sh notify <kind> <text>... | fm-telegram.sh notify <kind> -
#   fm-telegram.sh status
#
# send    Send one plain-text message to the configured chat. This is the raw
#         path, used for a reply the captain explicitly asked for. The inbound
#         collector deliberately sends no MESSAGE of its own; it confirms a
#         received message with a reaction instead, which the captain can see
#         at a glance and has nothing to dismiss.
# notify  Send one ESCALATION. <kind> is one of `blocker`, `review-ready`, or
#         `failure`, and nothing else is accepted.
# status  Report what is configured, for an operator setting the bridge up. It
#         prints whether a token is present, never any part of the token itself.
#
# WHAT FLOWS OUTWARD IS ESCALATIONS ONLY, and `notify` is what makes that a
# mechanism rather than a memo. Firstmate already has a definition of what is
# worth interrupting the captain for - a real blocker, work ready for review, a
# failure - and those three kinds are exactly it. Routine progress, empty polls,
# elapsed time, and no-change updates have no kind here and so cannot be sent
# through this path at all. There is deliberately no periodic digest: a channel
# that pings for everything is a channel the captain learns to ignore.
#
# Messages sent here LEAVE THIS MACHINE and reach Telegram's servers. Send short
# outcome summaries: never a credential, a file's contents, or a full record
# body. That judgement belongs to the caller; this script transports what it is
# given and only guarantees the bot token is not part of it.
#
# Inert until configured. With no TELEGRAM_BOT_TOKEN in the home's `.env` this
# exits 3 without sending or printing anything, so an unconfigured home can call
# it unconditionally. Configuration is owned by bin/fm-telegram-lib.sh.
#
# Exit status: 0 sent, 2 usage, 3 not configured, 4 the send was refused.
#
# Environment:
#   FM_HOME  operational home whose `.env` and state/ are used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

die() { printf 'fm-telegram: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

# Read the message body from the remaining arguments, or from stdin for `-`.
# stdin is the safe path for anything that might contain shell metacharacters,
# and the only path for a body with newlines.
read_body() {
  if [ "$#" -eq 0 ]; then
    return 1
  elif [ "$1" = "-" ]; then
    cat
  else
    printf '%s' "$*"
  fi
}

# One place that turns a resolved configuration into a sent message, so `send`
# and `notify` cannot drift on what "configured" means or what gets reported.
deliver() {  # <text>
  local text=$1 response ok
  [ -n "${text//[[:space:]]/}" ] || die "refusing to send an empty message"
  need curl
  need jq
  fm_telegram_allowlisted || {
    printf 'fm-telegram: no chat id is configured; set TELEGRAM_ALLOWED_CHAT_ID in %s\n' \
      "${FM_TELEGRAM_ENV_FILE:-$FM_HOME/.env}" >&2
    exit 3
  }
  response=$(fm_telegram_send_text "$FM_TG_CHAT" "$text") || true
  ok=$(printf '%s' "$response" | jq -r 'if type == "object" then (.ok // false) else false end' 2>/dev/null) || ok=false
  if [ "$ok" != "true" ]; then
    # The response has already been through the redactor, so it is safe to show.
    printf 'fm-telegram: send was refused: %s\n' \
      "$(printf '%s' "$response" | tr '\n' ' ' | cut -c1-300)" >&2
    exit 4
  fi
  printf 'sent\n'
}

cmd_send() {
  local body
  body=$(read_body "$@") || usage
  deliver "$body"
}

# The escalation tier. An unknown kind is refused rather than sent with a
# generic prefix, because the whole value of this path is that everything
# arriving through it is something the captain actually wants interrupting.
cmd_notify() {
  local kind=${1-} body label
  [ -n "$kind" ] || usage
  shift
  case "$kind" in
    blocker)      label='Blocked' ;;
    review-ready) label='Ready for review' ;;
    failure)      label='Failed' ;;
    *) die "unknown escalation kind: $kind (use blocker, review-ready, or failure)" ;;
  esac
  body=$(read_body "$@") || usage
  deliver "$label: $body"
}

cmd_status() {
  printf 'home        %s\n' "$FM_HOME"
  printf 'env file    %s\n' "${FM_TELEGRAM_ENV_FILE:-$FM_HOME/.env}"
  if fm_telegram_configured; then
    printf 'bot token   configured\n'
  else
    printf 'bot token   absent (bridge is inert)\n'
  fi
  printf 'bot handle  %s\n' "${FM_TG_NAME:-unknown}"
  if fm_telegram_allowlisted; then
    printf 'allowed chat %s\n' "$FM_TG_CHAT"
  elif [ -n "${FM_TG_CHAT-}" ]; then
    printf 'allowed chat INVALID (not a chat id): refusing every message\n'
  else
    printf 'allowed chat absent (inbound drops everything; see docs/telegram-bridge.md)\n'
  fi
}

fm_telegram_load

case "${1:-}" in
  send)   shift; fm_telegram_configured || exit 3; cmd_send "$@" ;;
  notify) shift; fm_telegram_configured || exit 3; cmd_notify "$@" ;;
  status) shift; cmd_status ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
