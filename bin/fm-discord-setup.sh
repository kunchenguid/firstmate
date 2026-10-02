#!/usr/bin/env bash
# Firstmate Discord connection/setup flow for an official application/bot.
#
# Usage:
#   fm-discord-setup.sh init [--redirect <uri>] [--permissions <bits>]
#   fm-discord-setup.sh callback --code <code> --state <state> [--redirect <uri>] [--guild <id>]
#   fm-discord-setup.sh verify [--guild <id>]
#   fm-discord-setup.sh status
#   fm-discord-setup.sh disconnect
#
# init prints the OAuth2 install URL (minimal scopes "bot applications.commands"
# and the minimal permission bits) and mints the CSRF state token (never
# printed: the operator copies it from their own browser redirect).
# callback validates state (single-use, short TTL), exchanges the code for
# the guild binding WITHOUT ever persisting an OAuth access token as a
# credential (the bot token in .env remains the only long-lived secret),
# identifies the guild/server, stores config/discord.json (mode 600, in a
# 0700 config dir), and verifies the bot can read that server. status prints
# a clear connected/disconnected line for Firstmate. No credentials, tokens,
# or guild IDs are hard-coded; nothing secret is logged.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

usage() { echo "usage: fm-discord-setup.sh (init|callback|verify|status|disconnect) [options]" >&2; }
help() { sed -n '2,/^set -u/p' "$0" | sed 's/^# //;s/^#//'; }

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift || true
command -v jq >/dev/null 2>&1 || { echo "fm-discord-setup: jq not found" >&2; exit 1; }
discord_load_config

config_file=$(discord_config_path)

write_config() { # <guild-id> <guild-name> <bot-id> <bot-username> <owner-id> <poll-channel-id>
  local dir tmp
  dir=$(dirname "$config_file")
  discord_private_dir "$dir" 700 >/dev/null || return 1
  tmp=$(umask 077; mktemp "$dir/.discord.XXXXXX") || return 1
  jq -n --arg guild_id "$1" --arg guild_name "$2" --arg bot_id "$3" --arg bot "$4" \
    --arg owner "$5" --arg channel "$6" \
    --arg client_id "${DISCORD_CLIENT_ID:-}" --argjson connected true \
    '{connected:$connected, client_id:$client_id, guild_id:$guild_id, guild_name:$guild_name, bot_user_id:$bot_id, bot_username:$bot, owner_user_id:$owner, poll_channel_id:$channel, updated_at:(now|floor)}' \
    > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$config_file" || { rm -f "$tmp"; return 1; }
  chmod 600 "$config_file" 2>/dev/null || true
}

case "$cmd" in
  --help|-h) help; exit 0 ;;
  init)
    redirect=; perms="$DISCORD_MIN_PERMISSIONS"
    while [ "$#" -gt 0 ]; do case "$1" in
      --redirect) shift; redirect=${1:-}; ;;
      --permissions) shift; perms=${1:-$DISCORD_MIN_PERMISSIONS}; ;;
      *) usage; exit 2 ;;
    esac; shift || true; done
    [ -n "$redirect" ] || redirect=${DISCORD_REDIRECT_URI:-}
    [ -n "$redirect" ] || { echo "fm-discord-setup: --redirect or DISCORD_REDIRECT_URI required" >&2; exit 2; }
    [ -n "${DISCORD_CLIENT_ID:-}" ] || { echo "fm-discord-setup: DISCORD_CLIENT_ID not configured" >&2; exit 1; }
    state=$(discord_oauth_state_new) || { echo "fm-discord-setup: cannot mint state" >&2; exit 1; }
    discord_oauth_authorize_url "$redirect" "$state" "$perms"
    # The state token itself is never printed: it travels in the operator's
    # own browser redirect, and the callback consumes it single-use.
    printf 'scopes=%s permissions=%s\n' "$DISCORD_OAUTH_SCOPES" "$perms" >&2
    ;;
  callback)
    code=; state=; redirect=; guild_hint=
    while [ "$#" -gt 0 ]; do case "$1" in
      --code) shift; code=${1:-}; ;;
      --state) shift; state=${1:-}; ;;
      --redirect) shift; redirect=${1:-}; ;;
      --guild) shift; guild_hint=${1:-}; ;;
      *) usage; exit 2 ;;
    esac; shift || true; done
    [ -n "$code" ] && [ -n "$state" ] || { usage; exit 2; }
    discord_oauth_state_check "$state" || { echo "fm-discord-setup: invalid OAuth state" >&2; exit 1; }
    [ -n "$redirect" ] || redirect=${DISCORD_REDIRECT_URI:-}
    # Exchange the code to prove the callback is genuine, but keep only the
    # guild identity: the bot token in .env stays the sole stored credential.
    [ -n "${DISCORD_CLIENT_ID:-}" ] && [ -n "${DISCORD_CLIENT_SECRET:-}" ] || { echo "fm-discord-setup: client id/secret not configured" >&2; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "fm-discord-setup: curl not found" >&2; exit 1; }
    body=$(mktemp "${TMPDIR:-/tmp}/fm-discord-cb.XXXXXX") || exit 1
    resp=$(mktemp "${TMPDIR:-/tmp}/fm-discord-cbresp.XXXXXX") || { rm -f "$body"; exit 1; }
    trap 'rm -f "$body" "$resp"' EXIT
    # Discord's token endpoint takes form-encoded bodies on the unversioned
    # API root. The secret travels only in this request body, never in logs.
    jq -n --arg cid "$DISCORD_CLIENT_ID" --arg sec "$DISCORD_CLIENT_SECRET" \
      --arg c "$code" --arg r "$redirect" \
      '"client_id=" + ($cid|@uri) + "&client_secret=" + ($sec|@uri) + "&grant_type=authorization_code&code=" + ($c|@uri) + "&redirect_uri=" + ($r|@uri)' -r > "$body"
    http=$(curl -m 15 -s -o "$resp" -w '%{http_code}' -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-binary "@$body" "$DISCORD_OAUTH_BASE/oauth2/token" 2>/dev/null) || { echo "fm-discord-setup: token exchange transport failure" >&2; exit 1; }
    case "$http" in 2[0-9][0-9]) ;; *) echo "fm-discord-setup: token exchange failed (HTTP $http)" >&2; exit 1 ;; esac
    # The bot-authorization flow returns the installed guild in the exchange
    # response; otherwise the installer names it explicitly with --guild. The
    # bot-token guild lookup in verify below is the authoritative check.
    guild=$(jq -r '.guild.id // empty' "$resp" 2>/dev/null || true)
    [ -n "$guild" ] || guild=$guild_hint
    [ -n "$guild" ] || { echo "fm-discord-setup: callback response carries no guild; pass --guild" >&2; exit 1; }
    rm -f "$body" "$resp"; trap - EXIT
    if [ -n "${DISCORD_GUILD_ID:-}" ] && [ "$guild" != "$DISCORD_GUILD_ID" ]; then
      echo "fm-discord-setup: guild $guild does not match configured DISCORD_GUILD_ID" >&2; exit 1
    fi
    "$SCRIPT_DIR/fm-discord-setup.sh" verify --guild "$guild" || exit 1
    ;;
  verify)
    guild=
    while [ "$#" -gt 0 ]; do case "$1" in --guild) shift; guild=${1:-}; ;; *) usage; exit 2 ;; esac; shift || true; done
    [ -n "$guild" ] || guild=${DISCORD_GUILD_ID:-}
    [ -n "$guild" ] || { echo "fm-discord-setup: no guild (pass --guild or set DISCORD_GUILD_ID)" >&2; exit 2; }
    discord_load_config
    [ -n "${DISCORD_BOT_TOKEN:-}" ] || { echo "fm-discord-setup: DISCORD_BOT_TOKEN not configured" >&2; exit 1; }
    out=$(mktemp "${TMPDIR:-/tmp}/fm-discord-verify.XXXXXX") || exit 1
    trap 'rm -f "$out"' EXIT
    read -r code _retry < <(discord_api GET "/users/@me" "" "$out") || { echo "fm-discord-setup: bot auth failed" >&2; exit 1; }
    case "$code" in 2[0-9][0-9]) ;; 401|403) echo "fm-discord-setup: bot token rejected (HTTP $code)" >&2; exit 1 ;; *) echo "fm-discord-setup: bot auth error HTTP $code" >&2; exit 1 ;; esac
    bot_id=$(jq -r '.id // empty' "$out" 2>/dev/null); bot_name=$(jq -r '.username // empty' "$out" 2>/dev/null)
    read -r code _retry < <(discord_api GET "/guilds/$guild" "" "$out") || { echo "fm-discord-setup: guild lookup failed" >&2; exit 1; }
    case "$code" in 2[0-9][0-9]) ;; 401|403|404) echo "fm-discord-setup: bot cannot access guild $guild (HTTP $code)" >&2; exit 1 ;; *) echo "fm-discord-setup: guild lookup HTTP $code" >&2; exit 1 ;; esac
    guild_name=$(jq -r '.name // empty' "$out" 2>/dev/null)
    rm -f "$out"; trap - EXIT
    # Persist the resolved bot id (the poll refuses until it is known), the
    # owner from configuration (empty until the operator sets it; inbound
    # routing refuses until it is set), and the REST fallback channel.
    write_config "$guild" "$guild_name" "$bot_id" "$bot_name" "${DISCORD_OWNER_USER_ID:-}" "${DISCORD_CHANNEL_ID:-}" \
      || { echo "fm-discord-setup: cannot persist config" >&2; exit 1; }
    printf 'discord: connected guild=%s name=%s bot=%s\n' "$guild" "$guild_name" "$bot_name"
    ;;
  status)
    if [ -f "$config_file" ] && [ "$(jq -r '.connected // false' "$config_file" 2>/dev/null)" = true ]; then
      if [ -n "$(jq -r '.owner_user_id // empty' "$config_file" 2>/dev/null)" ]; then owner_state="set"; else owner_state="unset"; fi
      printf 'discord: connected guild=%s name=%s owner=%s\n' \
        "$(jq -r '.guild_id // "?"' "$config_file")" "$(jq -r '.guild_name // "?"' "$config_file")" "$owner_state"
      [ "$owner_state" = set ] || \
        printf 'discord: WARNING owner_user_id is empty; inbound routing refuses everything until DISCORD_OWNER_USER_ID is set\n'
    else
      printf 'discord: disconnected (no verified guild binding; set DISCORD_CLIENT_ID and DISCORD_BOT_TOKEN, then run init)\n'
    fi
    ;;
  disconnect)
    rm -f "$config_file" 2>/dev/null || true
    printf 'discord: disconnected (remove DISCORD_BOT_TOKEN from %s/.env to fully revoke)\n' "${FM_HOME:-}"
    ;;
  *) usage; exit 2 ;;
esac
