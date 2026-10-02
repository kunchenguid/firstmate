#!/usr/bin/env bash
# Discord application/slash-command surface for Firstmate.
#
# Usage:
#   fm-discord-commands.sh register
#   fm-discord-commands.sh verify --signature <hex> --timestamp <ts> --body-file <path>
#   fm-discord-commands.sh handle --interaction-file <json>
#
# register installs the minimal command surface (currently: /firstmate with
# subcommands ask and status) via PUT /applications/<id>/commands, reusing
# Firstmate's general command/action model downstream instead of building a
# large command system here. verify validates Discord interaction signatures
# (Ed25519; requires python3 + PyNaCl when available, otherwise refuses
# closed rather than accepting) and refuses stale timestamps. handle maps a
# verified interaction to a state/discord-inbox record and prints the wake
# line; it verifies the signature itself over the raw interaction bytes
# before trusting any field (PING included) and enforces the same
# owner-only guild/user authorization as the message path, refusing closed
# when the signature, timestamp, sender, guild, or configuration is
# unknown. The operator's HTTP server pipes each received interaction body
# to handle with its X-Signature-Ed25519 / X-Signature-Timestamp headers;
# the HTTP server itself is outside this integration's scope.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

usage() { echo "usage: fm-discord-commands.sh (register|verify|handle) [options]" >&2; }
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
    file=; sig=; ts=
    while [ "$#" -gt 0 ]; do case "$1" in
      --interaction-file) shift; file=${1:-}; ;;
      --signature) shift; sig=${1:-}; ;;
      --timestamp) shift; ts=${1:-}; ;;
      *) usage; exit 2 ;; esac; shift || true; done
    [ -n "$file" ] && [ -f "$file" ] || { usage; exit 2; }
    # The signature covers the raw interaction bytes, so verify before
    # trusting any field. Missing signature material is a refusal, never a
    # downgrade to unverified handling.
    [ -n "$sig" ] && [ -n "$ts" ] || { echo "fm-discord-commands: unverified interaction refused (pass --signature and --timestamp from the Discord headers)" >&2; exit 1; }
    "$SCRIPT_DIR/fm-discord-commands.sh" verify --signature "$sig" --timestamp "$ts" --body-file "$file" || exit 1
    itype=$(jq -r '.type // 0' "$file")
    [ "$itype" = 1 ] && { printf '{"type":1}\n'; exit 0; } # PING
    name=$(jq -r '.data.name // empty' "$file")
    sub=$(jq -r '.data.options[0].name // empty' "$file")
    [ "$name" = firstmate ] || { echo "fm-discord-commands: unknown command" >&2; exit 1; }
    case "$sub" in ask|status) ;; *) echo "fm-discord-commands: unknown subcommand" >&2; exit 1 ;; esac
    # Same owner-only gate as the message path: guild interactions carry
    # member.user.id, direct-message interactions carry user.id.
    iguild=$(jq -r '.guild_id // empty' "$file")
    iuser=$(jq -r '.member.user.id // .user.id // empty' "$file")
    discord_require_guild "$iguild" || { echo "fm-discord-commands: refusing unknown guild" >&2; exit 1; }
    discord_authorize_sender "$iuser" "$iguild" "" || { echo "fm-discord-commands: refusing unauthorized interaction author" >&2; exit 1; }
    iid=$(jq -r '.id // empty' "$file")
    case "$iid" in ''|.*|*[!A-Za-z0-9._-]*) echo "fm-discord-commands: unsafe interaction id" >&2; exit 1 ;; esac
    discord_seen_claim "$iid"
    case "$?" in 0) ;; 1) exit 0 ;; *) exit 1 ;; esac
    inbox="$STATE/discord-inbox"; discord_private_dir "$inbox" 700 >/dev/null || exit 1
    jq --arg sub "$sub" --arg user "$iuser" --arg guild "$iguild" \
      '. + {firstmate_command:$sub, user_id:$user, guild_id:$guild, received_at:(now|todate)}' "$file" > "$inbox/$iid.json.tmp" || exit 1
    chmod 600 "$inbox/$iid.json.tmp"; mv -f "$inbox/$iid.json.tmp" "$inbox/$iid.json"
    if [ "$sub" = status ]; then
      printf '{"type":4,"data":{"content":"Firstmate: connected and listening; run fm-discord-setup.sh status on the host for full status."}}\n'
    else
      printf '{"type":4,"data":{"content":"Firstmate received your request and is working on it."}}\n'
    fi
    printf 'discord-command %s %s\n' "$iid" "$sub"
    ;;
  *) usage; exit 2 ;;
esac
