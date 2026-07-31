#!/usr/bin/env bash
# Configure or disable the private one-captain Telegram bridge.
#
# Usage:
#   fm-telegram-setup.sh pair [--token-file <owner-only-file>]
#   fm-telegram-setup.sh status
#   fm-telegram-setup.sh disable
#
# `pair` never accepts a token as an argument.
# Without --token-file it reads the token silently from a local terminal.
# It verifies the dedicated bot, inspects only numeric IDs from pending private
# messages, and requires the operator to type an exact `PAIR <user> <chat>`
# confirmation before publishing config/telegram/bridge.json as mode 0600.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: fm-telegram-setup.sh pair [--token-file <owner-only-file>]
       fm-telegram-setup.sh status
       fm-telegram-setup.sh disable

Never paste the bot token into Telegram or pass it on the command line.
EOF
}

make_payload() {
  local var_name=$1
  local file
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-setup.XXXXXX") || return 1
  chmod 0600 "$file" || { rm -f -- "$file"; return 1; }
  printf -v "$var_name" '%s' "$file"
}

api_json() { # <method> <payload> <body>
  local method=$1 payload=$2 body=$3
  if ! fmtg_api_call "$method" "$payload" "$body" 15; then
    echo "telegram setup: Telegram request outcome was uncertain; nothing was configured" >&2
    return 1
  fi
  case "$FMTG_API_HTTP" in
    200) ;;
    *) echo "telegram setup: Telegram returned HTTP $FMTG_API_HTTP; nothing was configured" >&2; return 1 ;;
  esac
  jq -e '.ok == true' "$body" >/dev/null 2>&1 \
    || { echo "telegram setup: Telegram rejected the request; nothing was configured" >&2; return 1; }
}

command=${1:-}
case "$command" in
  status)
    if fmtg_load_config; then
      echo "Telegram bridge: enabled for one private captain chat"
      exit 0
    fi
    if [ "$FMTG_CONFIG_STATUS" = invalid ]; then
      echo "Telegram bridge: disabled - local config is unsafe or incomplete"
      exit 1
    fi
    echo "Telegram bridge: disabled"
    exit 0
    ;;
  disable)
    if ! fmtg_load_config; then
      if [ "$FMTG_CONFIG_STATUS" = off ]; then
        echo "Telegram bridge: already disabled"
        exit 0
      fi
      echo "telegram setup: refusing to rewrite unsafe local config" >&2
      exit 1
    fi
    raw=$(fm_private_read_file "$FMTG_CONFIG_FILE" 600) || exit 1
    printf '%s' "$raw" | jq '.enabled=false' \
      | fmtg_json_publish "$FMTG_CONFIG_DIR" bridge.json \
      || { echo "telegram setup: could not disable local config" >&2; exit 1; }
    echo "Telegram bridge: disabled locally; rerun session start to retire polling artifacts"
    exit 0
    ;;
  pair) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

TOKEN_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --token-file)
      [ "$#" -gt 1 ] || { usage; exit 2; }
      TOKEN_FILE=$2
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "telegram setup: curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "telegram setup: jq is required" >&2; exit 1; }

if [ -n "$TOKEN_FILE" ]; then
  FMTG_TOKEN=$(fm_private_read_file "$TOKEN_FILE" 600) \
    || { echo "telegram setup: token file must be owner-only mode 0600, regular, and single-link" >&2; exit 1; }
  FMTG_TOKEN=${FMTG_TOKEN%$'\n'}
else
  [ -t 0 ] || { echo "telegram setup: use a local terminal or --token-file" >&2; exit 1; }
  printf 'Bot token (input hidden): ' >&2
  IFS= read -r -s FMTG_TOKEN
  printf '\n' >&2
fi

printf '%s' "$FMTG_TOKEN" | jq -R -e 'test("^[0-9]{6,20}:[A-Za-z0-9_-]{30,110}$")' >/dev/null 2>&1 \
  || { echo "telegram setup: token format is invalid" >&2; exit 1; }
[ "${#FMTG_TOKEN}" -ge 40 ] && [ "${#FMTG_TOKEN}" -le 128 ] \
  || { echo "telegram setup: token format is invalid" >&2; exit 1; }

PAYLOAD=
BODY=
UPDATES=
trap 'rm -f -- "$PAYLOAD" "$BODY" "$UPDATES"' EXIT
make_payload PAYLOAD || exit 1
make_payload BODY || exit 1
printf '{}\n' > "$PAYLOAD"
api_json getMe "$PAYLOAD" "$BODY" || exit 1
jq -e '.result.is_bot == true and (.result.id | type == "number")' "$BODY" >/dev/null 2>&1 \
  || { echo "telegram setup: getMe did not identify a bot" >&2; exit 1; }

make_payload UPDATES || exit 1
printf '{"timeout":0,"limit":100,"allowed_updates":["message"]}\n' > "$PAYLOAD"
api_json getUpdates "$PAYLOAD" "$UPDATES" || exit 1

CANDIDATES=$(jq -r '
  .result[]?
  | select(.message.chat.type == "private")
  | select((.message.from.is_bot // false) == false)
  | select((.message.from.id | tostring) == (.message.chat.id | tostring))
  | "\(.message.from.id) \(.message.chat.id)"
' "$UPDATES" 2>/dev/null | LC_ALL=C sort -u)
[ -n "$CANDIDATES" ] \
  || { echo "telegram setup: no pending private message found; message the dedicated bot, then rerun pair" >&2; exit 1; }

echo "Pending private-chat numeric IDs:"
while IFS=' ' read -r candidate_user candidate_chat; do
  [ -n "$candidate_user" ] || continue
  printf '  user_id=%s chat_id=%s\n' "$candidate_user" "$candidate_chat"
done <<EOF
$CANDIDATES
EOF
echo "Type the exact pair to allow, as: PAIR <user_id> <chat_id>"
IFS=' ' read -r confirm_word confirm_user confirm_chat confirm_extra
[ "$confirm_word" = PAIR ] && [ -n "$confirm_user" ] && [ -n "$confirm_chat" ] && [ -z "${confirm_extra:-}" ] \
  || { echo "telegram setup: exact PAIR confirmation required" >&2; exit 1; }
printf '%s\n' "$CANDIDATES" | grep -Fx "$confirm_user $confirm_chat" >/dev/null 2>&1 \
  || { echo "telegram setup: confirmed IDs were not a pending private-chat pair" >&2; exit 1; }
[ "$confirm_user" = "$confirm_chat" ] \
  || { echo "telegram setup: v1 supports one direct private chat only" >&2; exit 1; }

jq -n \
  --arg token "$FMTG_TOKEN" \
  --arg user "$confirm_user" \
  --arg chat "$confirm_chat" \
  '{version:1,enabled:true,bot_token:$token,allowed_user_id:$user,allowed_chat_id:$chat}' \
  | fmtg_json_publish "$FMTG_CONFIG_DIR" bridge.json \
  || { echo "telegram setup: could not publish owner-only local config" >&2; exit 1; }

unset FMTG_TOKEN
echo "Telegram bridge: paired locally for one private captain chat; rerun session start to activate polling"
