#!/usr/bin/env bash
# Receive Discord channel messages and route them into Firstmate's pipeline.
#
# Usage:
#   fm-discord-poll.sh --channel <id> [--limit <n>] [--once]
#   fm-discord-poll.sh --event-file <gateway-event.json>
#   fm-discord-poll.sh [--once]
#
# A bare invocation (the watcher path via state/discord-watch.check.sh)
# resolves its channel from DISCORD_CHANNEL_ID or config/discord.json and
# stays silent when the REST fallback is unconfigured; the Gateway in
# bin/fm-discord-gateway.py is the primary mechanism, not aggressive
# polling. --event-file maps one Gateway MESSAGE_CREATE event through the
# same idempotent routing. New messages are stashed at
# state/discord-inbox/<message-id>.json with guild, channel, user, message
# id, timestamps, and reply/thread context preserved, then one wake line
# "discord-message <message-id>" is printed per new message.
#
# Routing guards, all fail-closed and checked before any stash or wake:
# unknown senders are refused (owner-only via DISCORD_OWNER_USER_ID),
# unknown guilds are refused, our own bot messages are ignored (and polling
# refuses entirely until the bot user id is resolved), duplicates are
# absorbed via state/discord-seen/, and empty-content messages are dropped
# before the dedup marker is claimed. This script never executes asks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

usage() { echo "usage: fm-discord-poll.sh (--channel <id> [--limit <n>] [--once] | --event-file <json> | [--once])" >&2; }
help() { sed -n '2,/^set -u/p' "$0" | sed 's/^# //;s/^#//'; }

channel=; limit=25; event_file=; once=0
while [ "$#" -gt 0 ]; do case "$1" in
  --help|-h) help; exit 0 ;;
  --channel) shift; channel=${1:-}; ;;
  --limit) shift; limit=${1:-25}; ;;
  --once) once=1 ;;
  --event-file) shift; event_file=${1:-}; ;;
  *) usage; exit 2 ;;
esac; shift || true; done
# --once is the documented single bounded pass; a bare --channel call takes
# the same single pass so the watcher owns the cadence, never this script.
case "${once:-0}" in 0|1) ;; *) usage; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { echo "fm-discord-poll: jq not found" >&2; exit 1; }
discord_load_config
[ -n "${DISCORD_BOT_TOKEN:-}" ] || exit 0  # inert when not configured
# Refuse to poll until the bot user id is resolved (verify persists it):
# a half-configured home must never route its own replies as user input.
if ! discord_self_known; then
  discord_diag_throttled "no-bot-id" 3600 "fm-discord-poll: bot user id unknown; run fm-discord-setup.sh verify before polling" >&2
  exit 0
fi
inbox=$(discord_private_dir "$STATE/discord-inbox" 700) || exit 0

route_message_file() { # <message.json>
  local f=$1 mid guild ch author bot ts content ref
  mid=$(jq -r '.id // empty' "$f" 2>/dev/null)
  case "$mid" in ''|.*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  guild=$(jq -r '.guild_id // empty' "$f" 2>/dev/null)
  ch=$(jq -r '.channel_id // empty' "$f" 2>/dev/null)
  author=$(jq -r '.author.id // empty' "$f" 2>/dev/null)
  bot=$(jq -r '.author.bot // false' "$f" 2>/dev/null)
  # Ignore anything any bot generated, unconditionally: this filter cannot
  # fail open while the bot id is still unknown, and the owner gate below
  # refuses non-owner humans regardless.
  [ "$bot" = true ] && return 0
  discord_is_self "$author" && return 0
  # Evaluate content before claiming the dedup marker so attachment-only or
  # embed-only messages are not permanently absorbed without a trace.
  content=$(jq -r '.content // ""' "$f" 2>/dev/null)
  if [ -z "$content" ]; then
    printf 'discord-poll: ignoring contentless message %s\n' "$(discord_redact "$mid")" >&2
    return 0
  fi
  # Owner-only authorization, fail closed on unknown sender/guild/channel
  # or missing configuration. Non-owner chatter is routine, so it stays
  # silent; only home misconfiguration gets a (throttled) diagnostic.
  if ! discord_require_guild "$guild"; then return 0; fi
  if [ -z "$(discord_effective_owner)" ]; then
    discord_diag_throttled "no-owner" 3600 "fm-discord-poll: DISCORD_OWNER_USER_ID not configured; refusing inbound messages until the owner is set" >&2
    return 0
  fi
  if ! discord_authorize_sender "$author" "$guild" "$ch"; then return 0; fi
  # Idempotent event processing: duplicates are absorbed silently.
  discord_seen_claim "$mid"
  case "$?" in 0) ;; 1) return 0 ;; *) echo "fm-discord-poll: dedup store failure" >&2; return 0 ;; esac
  ts=$(jq -r '.timestamp // empty' "$f" 2>/dev/null)
  ref=$(jq -c '{message_id:(.message_reference.message_id // null), channel_id:(.message_reference.channel_id // null), thread_id:(.thread_id // null)}' "$f" 2>/dev/null)
  out="$inbox/$mid.json"
  jq --arg guild "$guild" --arg ch "$ch" --arg author "$author" --arg ts "$ts" --argjson ref "$ref" \
    '. + {guild_id:$guild, channel_id:$ch, user_id:$author, received_at:$ts, reply_context:$ref}' "$f" > "$out.tmp" 2>/dev/null || return 0
  chmod 600 "$out.tmp" 2>/dev/null
  mv -f "$out.tmp" "$out" 2>/dev/null || return 0
  printf 'discord-message %s\n' "$mid"
}

if [ -n "$event_file" ]; then
  [ -f "$event_file" ] || { echo "fm-discord-poll: event file missing" >&2; exit 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-discord-evt.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  # Gateway MESSAGE_CREATE envelopes carry {t:"MESSAGE_CREATE", d:{...}}.
  jq -c 'if has("d") and (.t // "") == "MESSAGE_CREATE" then .d else . end' "$event_file" > "$tmp" || exit 1
  route_message_file "$tmp"
  rm -f "$tmp"; trap - EXIT
  exit 0
fi

if [ -z "$channel" ]; then
  # Watcher path: resolve the REST channel from configuration. Silent when
  # the fallback is unconfigured; the Gateway remains the primary inbound.
  channel=$(discord_effective_channel)
  [ -n "$channel" ] || exit 0
fi
case "$channel" in ''|*[!A-Za-z0-9_-]*) echo "fm-discord-poll: unsafe channel id" >&2; exit 2 ;; esac
case "$limit" in ''|*[!0-9]*) limit=25 ;; esac
[ "$limit" -ge 1 ] 2>/dev/null || limit=25
[ "$limit" -le 100 ] 2>/dev/null || limit=100

out=$(mktemp "${TMPDIR:-/tmp}/fm-discord-msgs.XXXXXX") || exit 1
trap 'rm -f "$out"' EXIT
read -r code _retry < <(discord_api GET "/channels/$channel/messages?limit=$limit" "" "$out") || exit 0
case "$code" in
  2[0-9][0-9]) ;;
  401|403) echo "fm-discord-poll: permission failure HTTP $code for channel $channel" >&2; exit 0 ;;
  429) exit 0 ;; # rate limited: stay silent, retry next cycle
  *) exit 0 ;;
esac
jq -c '.[]' "$out" 2>/dev/null | while IFS= read -r msg; do
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-discord-msg.XXXXXX") || continue
  printf '%s' "$msg" > "$tmp"
  route_message_file "$tmp"
  rm -f "$tmp"
done
rm -f "$out"; trap - EXIT
