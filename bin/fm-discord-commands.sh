#!/usr/bin/env bash
# Discord application/slash-command surface for Firstmate.
#
# Reply path is outbound-only (Relay-style): slash interactions arrive over
# the gateway connection this home opens itself (INTERACTION_CREATE routed
# by bin/fm-discord-gateway.py into bin/fm-discord-poll.sh --event-file,
# already authenticated by the gateway session, so no Ed25519 signature
# check applies there) and are answered through the REST interaction
# callback (POST /interactions/{id}/{token}/callback). Message-based
# equivalents (!fm ask <question>, !fm status) need no interaction delivery
# at all and are handled from plain MESSAGE_CREATE content. Nothing here
# listens on a socket or needs a public URL: do NOT set an interactions
# endpoint URL in the Discord Developer Portal; the self-hosted HTTPS
# interaction path is explicitly unsupported by this integration.
#
# Usage:
#   fm-discord-commands.sh register
#   fm-discord-commands.sh verify --signature <hex> --timestamp <ts> --body-file <path>
#   fm-discord-commands.sh handle --gateway --interaction-file <json>
#   fm-discord-commands.sh handle-message --message-file <json>
#
# register installs the minimal command surface (currently: /firstmate with
# subcommands ask and status) via PUT /applications/<id>/commands, reusing
# Firstmate's general command/action model downstream instead of building a
# large command system here. verify keeps the legacy Ed25519 check
# available for tests only; the live path never uses it because gateway
# delivery is already session-authenticated. handle --gateway maps a
# gateway-delivered interaction to a state/discord-inbox record, answers
# the interaction via the REST callback, and prints the wake line; it
# enforces the same owner-only guild/user authorization as the message
# path, refusing closed when the sender, guild, or configuration is
# unknown. handle-message maps a !fm-prefixed plain message to the same
# inbox/wake shape so ask/status work even where slash delivery is
# unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

usage() { echo "usage: fm-discord-commands.sh (register|verify|handle --gateway|handle-message) [options]" >&2; }
help() { sed -n '2,/^set -u/p' "$0" | sed 's/^# //;s/^#//'; }

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift || true
case "$cmd" in --help|-h) help; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { echo "fm-discord-commands: jq not found" >&2; exit 1; }
discord_load_config

case "$cmd" in
  register)
    [ -n "${DISCORD_CLIENT_ID:-}" ] && [ -n "${DISCORD_BOT_TOKEN:-}" ] || { echo "fm-discord-commands: not configured" >&2; exit 1; }
    payload=$(mktemp "${TMPDIR:-/tmp}/fm-discord-cmds.XXXXXX") || exit 1
    out=$(mktemp "${TMPDIR:-/tmp}/fm-discord-cmds-out.XXXXXX") || { rm -f "$payload"; exit 1; }
    trap 'rm -f "$payload" "$out"' EXIT
    jq -n '[
      {name:"firstmate", description:"Talk to Firstmate",
       options:[
         {type:1, name:"ask", description:"Ask Firstmate a question",
          options:[{type:3, name:"question", description:"The question", required:true}]},
         {type:1, name:"status", description:"Show Firstmate connection status"}
       ]}
    ]' > "$payload" || exit 1
    read -r code _retry < <(discord_api PUT "/applications/$DISCORD_CLIENT_ID/commands" "$payload" "$out") || exit 1
    rm -f "$payload" "$out"; trap - EXIT
    case "$code" in 2[0-9][0-9]) printf 'discord: registered /firstmate ask,status\n' ;; *) echo "fm-discord-commands: register failed HTTP $code" >&2; exit 1 ;; esac
    ;;
  verify)
    sig=; ts=; body=
    while [ "$#" -gt 0 ]; do case "$1" in
      --signature) shift; sig=${1:-}; ;; --timestamp) shift; ts=${1:-}; ;; --body-file) shift; body=${1:-}; ;;
      *) usage; exit 2 ;; esac; shift || true; done
    [ -n "$sig" ] && [ -n "$ts" ] && [ -n "$body" ] || { usage; exit 2; }
    pubkey=${DISCORD_PUBLIC_KEY:-$(fmx_env_get DISCORD_PUBLIC_KEY "$(discord_env_file)")}
    [ -n "$pubkey" ] || { echo "fm-discord-commands: DISCORD_PUBLIC_KEY not configured; refusing" >&2; exit 1; }
    # Replay guard: Discord signs the timestamp, but a captured valid pair
    # stays valid forever unless the timestamp itself expires. Refuse skew
    # beyond five minutes either way.
    now=$(date +%s)
    case "$ts" in ''|*[!0-9]*) echo "fm-discord-commands: bad interaction timestamp" >&2; exit 1 ;; esac
    [ "$ts" -ge $((now - 300)) ] && [ "$ts" -le $((now + 300)) ] \
      || { echo "fm-discord-commands: stale interaction timestamp" >&2; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "fm-discord-commands: python3 required for signature verify" >&2; exit 1; }
    python3 - "$sig" "$ts" "$body" "$pubkey" <<'PY'
import sys
sig, ts, body_path, pubkey = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    from nacl.signing import VerifyKey
    from nacl.exceptions import BadSignatureError
except Exception:
    print("fm-discord-commands: PyNaCl unavailable; refusing to accept interaction", file=sys.stderr)
    sys.exit(1)
with open(body_path, "rb") as f:
    raw = f.read()
try:
    VerifyKey(bytes.fromhex(pubkey)).verify(ts.encode() + raw, bytes.fromhex(sig))
except BadSignatureError:
    print("fm-discord-commands: bad interaction signature", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
    ;;
  handle)
    file=; gateway=0
    while [ "$#" -gt 0 ]; do case "$1" in
      --interaction-file) shift; file=${1:-}; ;;
      --gateway) gateway=1; ;;
      --signature|--timestamp) shift; _legacy=${1:-}; ;; # legacy HTTPS path: unsupported, ignored
      *) usage; exit 2 ;; esac; shift || true; done
    [ -n "$file" ] && [ -f "$file" ] || { usage; exit 2; }
    # Live interactions arrive over the gateway session, which Discord
    # authenticates at connect time; no Ed25519 check applies. The legacy
    # self-hosted HTTPS signature path is explicitly unsupported: passing
    # --signature/--timestamp neither verifies nor authorizes anything.
    [ "$gateway" = 1 ] || { echo "fm-discord-commands: only gateway-delivered interactions are supported (pass --gateway); the self-hosted HTTPS endpoint path is unsupported" >&2; exit 1; }
    itype=$(jq -r '.type // 0' "$file")
    # PING over the gateway needs no callback: the session itself is the
    # liveness proof, so there is nothing to answer and nothing to wake.
    [ "$itype" = 1 ] && exit 0
    name=$(jq -r '.data.name // empty' "$file")
    sub=$(jq -r '.data.options[0].name // empty' "$file")
    [ "$name" = firstmate ] || { echo "fm-discord-commands: unknown command" >&2; exit 1; }
    case "$sub" in ask|status) ;; *) echo "fm-discord-commands: unknown subcommand" >&2; exit 1 ;; esac
    # Same owner-only gate as the message path: guild interactions carry
    # member.user.id, direct-message interactions carry user.id.
    iguild=$(jq -r '.guild_id // empty' "$file")
    iuser=$(jq -r '.member.user.id // .user.id // empty' "$file")
    ich=$(jq -r '.channel_id // .channel.id // empty' "$file")
    discord_require_guild "$iguild" || { echo "fm-discord-commands: refusing unknown guild" >&2; exit 1; }
    discord_authorize_sender "$iuser" "$iguild" "$ich" || { echo "fm-discord-commands: refusing unauthorized interaction author" >&2; exit 1; }
    iid=$(jq -r '.id // empty' "$file")
    case "$iid" in ''|.*|*[!A-Za-z0-9._-]*) echo "fm-discord-commands: unsafe interaction id" >&2; exit 1 ;; esac
    discord_seen_claim "$iid"
    case "$?" in 0) ;; 1) exit 0 ;; *) exit 1 ;; esac
    inbox="$STATE/discord-inbox"; discord_private_dir "$inbox" 700 >/dev/null || exit 1
    jq --arg sub "$sub" --arg user "$iuser" --arg guild "$iguild" \
      '. + {firstmate_command:$sub, user_id:$user, guild_id:$guild, received_at:(now|todate)}' "$file" > "$inbox/$iid.json.tmp" || exit 1
    chmod 600 "$inbox/$iid.json.tmp"; mv -f "$inbox/$iid.json.tmp" "$inbox/$iid.json"
    # Answer through the REST interaction callback (outbound POST the home
    # opens itself). The wake below still carries the work to the agent,
    # which follows up with fm-discord-send.sh; a failed callback only
    # logs, it never drops the wake.
    if [ "$sub" = status ]; then
      cb_content="Firstmate: connected and listening; run fm-discord-setup.sh status on the host for full status."
    else
      cb_content="Firstmate received your request and is working on it."
    fi
    itoken=$(jq -r '.token // empty' "$file")
    case "$itoken" in ''|*[$'\n\r']*) echo "fm-discord-commands: interaction has no callback token; wake only" >&2 ;; *)
      if cb_payload=$(mktemp "${TMPDIR:-/tmp}/fm-discord-cb.XXXXXX") && cb_out=$(mktemp "${TMPDIR:-/tmp}/fm-discord-cbout.XXXXXX") && {
        jq -n --arg c "$cb_content" '{type:4, data:{content:$c}}' > "$cb_payload" &&
        read -r cb_code _cb_retry < <(discord_api POST "/interactions/$iid/$itoken/callback" "$cb_payload" "$cb_out") &&
        case "$cb_code" in 2[0-9][0-9]) ;; *) echo "fm-discord-commands: interaction callback HTTP $cb_code; wake still queued" >&2 ;; esac
        rm -f "$cb_payload" "$cb_out"
      }; then
        :
      else echo "fm-discord-commands: interaction callback failed; wake still queued" >&2; rm -f "${cb_payload-}" "${cb_out-}"; fi ;; esac
    printf 'discord-command %s %s\n' "$iid" "$sub"
    ;;
  handle-message)
    # Message-based equivalents: !fm ask <question> / !fm status, parsed
    # from plain gateway/REST message content. Needs no interaction
    # delivery at all, so it works wherever MESSAGE_CREATE arrives.
    file=
    while [ "$#" -gt 0 ]; do case "$1" in
      --message-file) shift; file=${1:-}; ;;
      *) usage; exit 2 ;; esac; shift || true; done
    [ -n "$file" ] && [ -f "$file" ] || { usage; exit 2; }
    content=$(jq -r '.content // empty' "$file")
    rest=$(jq -rn --arg c "$content" '$c | if test("^[[:space:]]*!fm([[:space:]]|$)") then sub("^[[:space:]]*!fm[[:space:]]*"; "") elif test("^[[:space:]]*<@[^>]*>[[:space:]]+fm([[:space:]]|$)") then sub("^[[:space:]]*<@[^>]*>[[:space:]]+fm[[:space:]]*"; "") else "" end')
    [ -n "$rest" ] || { echo "fm-discord-commands: not a !fm command message" >&2; exit 1; }
    trimmed=${rest#"${rest%%[![:space:]]*}"}
    sub=${trimmed%%[[:space:]]*}
    tmp=${trimmed#"$sub"}
    qtext=${tmp#"${tmp%%[![:space:]]*}"}
    case "$sub" in ask|status) ;; *) echo "fm-discord-commands: unknown !fm subcommand" >&2; exit 1 ;; esac
    [ "$sub" = ask ] && [ -z "$qtext" ] && { echo "fm-discord-commands: !fm ask needs a question" >&2; exit 1; }
    mguild=$(jq -r '.guild_id // empty' "$file")
    muser=$(jq -r '.author.id // empty' "$file")
    mch=$(jq -r '.channel_id // empty' "$file")
    mid=$(jq -r '.id // empty' "$file")
    discord_require_guild "$mguild" || { echo "fm-discord-commands: refusing unknown guild" >&2; exit 1; }
    discord_authorize_sender "$muser" "$mguild" "$mch" || { echo "fm-discord-commands: refusing unauthorized command author" >&2; exit 1; }
    case "$mid" in ''|.*|*[!A-Za-z0-9._-]*) echo "fm-discord-commands: unsafe message id" >&2; exit 1 ;; esac
    cid="cmd-$mid"
    discord_seen_claim "$cid"
    case "$?" in 0) ;; 1) exit 0 ;; *) exit 1 ;; esac
    inbox="$STATE/discord-inbox"; discord_private_dir "$inbox" 700 >/dev/null || exit 1
    if [ "$sub" = ask ]; then
      jq --arg sub "$sub" --arg user "$muser" --arg guild "$mguild" --arg ch "$mch" --arg q "$qtext" --arg src "$mid" \
        '. + {firstmate_command:$sub, user_id:$user, guild_id:$guild, channel_id:$ch, question:$q, source_message_id:$src, via:"message", received_at:(now|todate)}' "$file" > "$inbox/$cid.json.tmp" || exit 1
    else
      jq --arg sub "$sub" --arg user "$muser" --arg guild "$mguild" --arg ch "$mch" --arg src "$mid" \
        '. + {firstmate_command:$sub, user_id:$user, guild_id:$guild, channel_id:$ch, source_message_id:$src, via:"message", received_at:(now|todate)}' "$file" > "$inbox/$cid.json.tmp" || exit 1
    fi
    chmod 600 "$inbox/$cid.json.tmp"; mv -f "$inbox/$cid.json.tmp" "$inbox/$cid.json"
    printf 'discord-command %s %s\n' "$cid" "$sub"
    ;;
  *) usage; exit 2 ;;
esac
