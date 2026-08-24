#!/usr/bin/env bash
# fm-miniapp-ask.sh - ask the captain one decision question through the Mini App.
#
#   fm-miniapp-ask.sh --text "Merge the fix now?" --option Merge --option Wait
#
#   --text <question>     required, shown as the page's heading
#   --option <label>      repeatable, at least one; the order is the order shown
#   --id <slug>           reuse a known id instead of generating one
#   --button <label>      the button label in the chat  (default "Answer")
#   --dry-run             print what would happen, send nothing, upload nothing
#
# The question is stored on the host as a file and only its id travels in the
# button's address. That is deliberate: the answer that lands in the inbox is
# then a label this side authored, never a string the page could have supplied.
#
# Settings and the bot token come from bin/fm-miniapp-lib.sh. This script needs
# FM_MINIAPP_SSH, FM_MINIAPP_ADDRESS, FM_MINIAPP_CHAT_ID, FM_MINIAPP_TOKEN_FILE
# and FM_MINIAPP_TOKEN_VAR; FM_MINIAPP_REMOTE_ROOT defaults to /root/fm-miniapp.
#
# On success it prints the question id and the address of the page, so the
# caller can name them without reading anything back off the host.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export FM_MINIAPP_TOOL=fm-miniapp-ask

# shellcheck source=bin/fm-miniapp-lib.sh
. "$SCRIPT_DIR/fm-miniapp-lib.sh"

usage() { sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

TEXT=''
BUTTON='Answer'
QUESTION_ID=''
DRY_RUN=0
OPTIONS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --text) TEXT=${2:-}; shift 2 ;;
    --option) OPTIONS+=("${2:-}"); shift 2 ;;
    --id) QUESTION_ID=${2:-}; shift 2 ;;
    --button) BUTTON=${2:-}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fm_miniapp_die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$TEXT" ] || fm_miniapp_die "--text is required"
[ ${#OPTIONS[@]} -gt 0 ] || fm_miniapp_die "at least one --option is required"

fm_miniapp_load_config FM_MINIAPP_SSH FM_MINIAPP_ADDRESS FM_MINIAPP_CHAT_ID \
  FM_MINIAPP_TOKEN_FILE FM_MINIAPP_TOKEN_VAR
: "${FM_MINIAPP_REMOTE_ROOT:=/root/fm-miniapp}"

# The id becomes part of a filename and of a URL, so keep it to the character
# set the service accepts; anything else is refused there rather than sanitised.
if [ -z "$QUESTION_ID" ]; then
  QUESTION_ID="q-$(date -u +%Y%m%d-%H%M%S)-$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
fi
case "$QUESTION_ID" in
  *[!A-Za-z0-9_-]*) fm_miniapp_die "--id must match [A-Za-z0-9_-]" ;;
esac

URL="https://$FM_MINIAPP_ADDRESS/?f=$QUESTION_ID"

# Built by python rather than by hand: a question is free text from a task and
# will contain quotes, newlines and umlauts sooner rather than later.
QUESTION_JSON=$(python3 -c '
import json, sys
question_id, text = sys.argv[1], sys.argv[2]
print(json.dumps({"id": question_id, "text": text, "options": sys.argv[3:]},
                 ensure_ascii=False))
' "$QUESTION_ID" "$TEXT" "${OPTIONS[@]}")

PAYLOAD=$(python3 -c '
import json, sys
chat_id, text, button, url = sys.argv[1:5]
print(json.dumps({
    "chat_id": int(chat_id),
    "text": text,
    "reply_markup": {"inline_keyboard": [[{"text": button, "web_app": {"url": url}}]]},
}, ensure_ascii=False))
' "$FM_MINIAPP_CHAT_ID" "$TEXT" "$BUTTON" "$URL")

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'question %s\n' "$QUESTION_ID"
  printf 'url      %s\n' "$URL"
  printf 'question file:\n%s\n' "$QUESTION_JSON"
  printf 'message:\n%s\n' "$PAYLOAD"
  exit 0
fi

printf '%s' "$QUESTION_JSON" | fm_miniapp_on_host \
  "umask 077 && mkdir -p '$FM_MINIAPP_REMOTE_ROOT/questions' && cat > '$FM_MINIAPP_REMOTE_ROOT/questions/$QUESTION_ID.json.tmp' && mv '$FM_MINIAPP_REMOTE_ROOT/questions/$QUESTION_ID.json.tmp' '$FM_MINIAPP_REMOTE_ROOT/questions/$QUESTION_ID.json'"

TOKEN=$(fm_miniapp_read_token)
# The token goes into the URL of a local curl call, which is why it is not
# echoed anywhere and why the response is filtered before printing.
RESPONSE=$(printf '%s' "$PAYLOAD" | curl -sS -m 20 -X POST \
  -H 'Content-Type: application/json' --data-binary @- \
  "https://api.telegram.org/bot$TOKEN/sendMessage")

if ! printf '%s' "$RESPONSE" | grep -q '"ok":true'; then
  # Telegram's error text can quote the request but never the token; still, only
  # the description is printed, not the raw body.
  DESCRIPTION=$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("description", "no description"))
except Exception: print("unreadable response")')
  fm_miniapp_die "Telegram refused the message: $DESCRIPTION"
fi

printf 'question %s\n' "$QUESTION_ID"
printf 'url      %s\n' "$URL"
