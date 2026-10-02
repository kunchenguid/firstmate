#!/usr/bin/env bash
# Send a Firstmate response back to Discord (outbound path).
#
# Usage:
#   fm-discord-send.sh <channel-id> [--reply-to <message-id>] <text>
#   fm-discord-send.sh <channel-id> [--reply-to <message-id>] --text-file <path>
#   fm-discord-send.sh <channel-id> [--reply-to <message-id>] -
#
# Chunks long responses to Discord's 2000-unit limit (never silently
# truncates); a reply that fits in one message goes out unnumbered, while a
# longer reply gets " (k/n)" thread suffixes consistent with the Relay's
# fmx_split_thread contract so the receiver sees ordering and continuity.
# Replies to the originating message when --reply-to is given, retries
# transient failures and 429 rate limits with the server's Retry-After, and
# exits non-zero with a structured diagnostic on permission or API errors.
# Text is JSON-encoded with jq; the bot token is never logged. An optional
# DISCORD_SEND_CHANNEL_IDS allowlist constrains outbound channels when set.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

usage() { echo "usage: fm-discord-send.sh <channel-id> [--reply-to <message-id>] <text> | --text-file <path> | -" >&2; }
help() { sed -n '2,/^set -u/p' "$0" | sed 's/^# //;s/^#//'; }

channel=${1:-}
[ -n "$channel" ] || { usage; exit 2; }
shift
case "$channel" in ''|*[!A-Za-z0-9_-]*) echo "fm-discord-send: unsafe channel id" >&2; exit 2 ;; esac

reply_to=
ARGS=()
while [ "$#" -gt 0 ]; do case "$1" in
  --help|-h) help; exit 0 ;;
  --reply-to) shift; reply_to=${1:-}; case "$reply_to" in ''|*[!A-Za-z0-9_-]*) echo "fm-discord-send: unsafe reply-to message id" >&2; exit 2 ;; esac ;;
  --text-file) shift; [ -n "${1:-}" ] || { usage; exit 2; }; TEXT=$(cat -- "$1") || exit 1; ARGS=(__file) ;;
  -) TEXT=$(cat); ARGS=(__stdin) ;;
  *) TEXT=$1; ARGS=(__arg) ;;
esac; shift || true; done
[ "${#ARGS[@]}" -eq 1 ] || { usage; exit 2; }
[ -n "${TEXT:-}" ] || { echo "fm-discord-send: empty text" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-discord-send: jq not found" >&2; exit 1; }
discord_load_config
[ -n "${DISCORD_BOT_TOKEN:-}" ] || { echo "fm-discord-send: DISCORD_BOT_TOKEN not configured" >&2; exit 1; }
if [ -n "${DISCORD_SEND_CHANNEL_IDS:-}" ]; then
  case ",${DISCORD_SEND_CHANNEL_IDS}," in
    *",$channel,"*) ;;
    *) echo "fm-discord-send: channel $channel outside DISCORD_SEND_CHANNEL_IDS" >&2; exit 2 ;;
  esac
fi

# Number multi-message replies " (k/n)" like fmx_split_thread; a reply that
# fits in one message stays unnumbered. The chunk budget reserves the suffix
# width (4 + 2*digits, plus the joining space) and iterates to a fixpoint so
# the suffix can never push a chunk over Discord's limit.
CHUNKS=$(printf '%s' "$TEXT" | discord_chunk_text "$DISCORD_CHUNK_BUDGET") || { echo "fm-discord-send: chunking failed" >&2; exit 1; }
N=$(printf '%s' "$CHUNKS" | jq 'length') || exit 1
if [ "$N" -gt 1 ]; then
  est=$N pass=0
  while [ "$pass" -lt 3 ]; do
    digits=${#est}
    budget=$((DISCORD_CHUNK_BUDGET - 4 - 2 * digits - 1))
    [ "$budget" -ge 1 ] || budget=1
    CHUNKS=$(printf '%s' "$TEXT" | discord_chunk_text "$budget") || { echo "fm-discord-send: chunking failed" >&2; exit 1; }
    N=$(printf '%s' "$CHUNKS" | jq 'length') || exit 1
    [ "$N" = "$est" ] && break
    est=$N; pass=$((pass + 1))
  done
  CHUNKS=$(printf '%s' "$CHUNKS" | jq --argjson n "$N" '[range(0; length) as $i | .[$i] + " (\($i + 1)/\($n))"]') || exit 1
fi
[ "$N" -gt 0 ] || { echo "fm-discord-send: empty text" >&2; exit 2; }

post_one() { # <text> <is-first>
  local text=$1 first=$2 payload out code retry attempt=0 max=4 backoff=1
  payload=$(mktemp "${TMPDIR:-/tmp}/fm-discord-payload.XXXXXX") || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/fm-discord-out.XXXXXX") || { rm -f "$payload"; return 1; }
  if [ "$first" = 1 ] && [ -n "$reply_to" ]; then
    jq -n --arg c "$text" --arg r "$reply_to" \
      '{content:$c, message_reference:{message_id:$r}, allowed_mentions:{replied_user:false}}' > "$payload" || { rm -f "$payload" "$out"; return 1; }
  else
    jq -n --arg c "$text" '{content:$c, allowed_mentions:{parse:[]}}' > "$payload" || { rm -f "$payload" "$out"; return 1; }
  fi
  while :; do
    read -r code retry < <(discord_api POST "/channels/$channel/messages" "$payload" "$out") || code=0
    case "$code" in
      2[0-9][0-9]) rm -f "$payload" "$out"; return 0 ;;
      429)
        attempt=$((attempt + 1)); [ "$attempt" -ge "$max" ] && { rm -f "$payload" "$out"; echo "fm-discord-send: rate limited, giving up" >&2; return 1; }
        sleep "${retry:-$backoff}"; backoff=$((backoff * 2)); continue ;;
      500|502|503|504)
        attempt=$((attempt + 1)); [ "$attempt" -ge "$max" ] && { rm -f "$payload" "$out"; echo "fm-discord-send: transient Discord error HTTP $code" >&2; return 1; }
        sleep "$backoff"; backoff=$((backoff * 2)); continue ;;
      401|403) rm -f "$payload" "$out"; echo "fm-discord-send: permission failure HTTP $code for channel $channel" >&2; return 2 ;;
      404) rm -f "$payload" "$out"; echo "fm-discord-send: unknown channel $channel (HTTP 404)" >&2; return 2 ;;
      *) rm -f "$payload" "$out"; echo "fm-discord-send: Discord API error HTTP $code for channel $channel" >&2; return 1 ;;
    esac
  done
}

i=0
while [ "$i" -lt "$N" ]; do
  chunk=$(printf '%s' "$CHUNKS" | jq -r ".[$i]") || exit 1
  if [ "$i" = 0 ]; then post_one "$chunk" 1 || exit $?; else post_one "$chunk" 0 || exit $?; fi
  i=$((i + 1))
done
printf 'sent %s message(s) to %s\n' "$N" "$channel"
