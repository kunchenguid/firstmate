#!/usr/bin/env bash
# tests/telegram-helpers.sh - a fake local Telegram Bot API server, plus fixture
# builders, for the private Telegram bridge suite.
#
# Source this from a test file:
#   # shellcheck source=tests/telegram-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/telegram-helpers.sh"
#
# THE FAKE SERVER
#   It is a real, stateful implementation of the two Bot API methods the bridge
#   uses, reached through the same transport the client actually speaks: a `curl`
#   shim that parses the mode-0600 `curl --config` file bin/fm-tg-lib.sh writes.
#   No socket is opened and no port is bound, so the suite stays hermetic and
#   cannot flake on a busy port, while still exercising the exact request the
#   client builds - including the fact that the bot token travels in that config
#   file and never in an argument vector.
#
#   getUpdates implements Telegram's real offset contract: confirming an offset
#   permanently deletes every update below it, and only updates at or above the
#   offset are returned. That is what makes crash, duplicate-delivery, and
#   offset-recovery behavior testable rather than assumed.
#
#   Server state lives in one directory, exported as FAKE_TG_DIR:
#     updates.json     the pending update queue (a JSON array)
#     sent.jsonl       one line per delivered sendMessage payload
#     argv.log         the shim's own argv, for asserting the token is absent
#     token-seen.log   tokens the server received, proving transport still works
#     calls.log        one "<method> <offset-or-->" line per request
#     budget.log       one "<method> max-time=<s> timeout=<s>" line per request,
#                      so the request's own deadlines can be asserted against the
#                      watcher's per-check kill budget
#
#   Behavior knobs, all read fresh per call from the environment:
#     FAKE_TG_GETUPDATES_CODE    HTTP status to return for getUpdates (default 200)
#     FAKE_TG_SENDMESSAGE_CODE   HTTP status to return for sendMessage (default 200)
#     FAKE_TG_SEND_FAIL_FROM     fail sendMessage from the Nth delivery onward
#     FAKE_TG_BODY_OVERRIDE      raw body to return for getUpdates instead of JSON

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tg_fake_api <dir>: install the fake Bot API server into <dir>/fakebin.
# Sets TG_FAKEBIN (the shim directory) and exports FAKE_TG_DIR (the server's
# state) in the CALLER's shell, so it must be called directly rather than in a
# command substitution, whose subshell would discard both.
# shellcheck disable=SC2034 # TG_FAKEBIN is read by the sourcing test file.
tg_fake_api() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  TG_FAKEBIN=$fakebin
  export FAKE_TG_DIR="$dir/bot-api"
  mkdir -p "$FAKE_TG_DIR"
  printf '[]\n' > "$FAKE_TG_DIR/updates.json"
  : > "$FAKE_TG_DIR/sent.jsonl"
  : > "$FAKE_TG_DIR/argv.log"
  : > "$FAKE_TG_DIR/token-seen.log"
  : > "$FAKE_TG_DIR/calls.log"
  : > "$FAKE_TG_DIR/budget.log"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Fake local Telegram Bot API server (see tests/telegram-helpers.sh).
set -u
state=${FAKE_TG_DIR:?fake bot api needs FAKE_TG_DIR}
printf '%s\n' "$*" >> "$state/argv.log"

cfg=
while [ $# -gt 0 ]; do
  case "$1" in
    --config) cfg=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$cfg" ] || { printf '000'; exit 0; }

url= ofile= payload= maxtime=
while IFS= read -r line; do
  case "$line" in
    'url = '*)        url=${line#url = } ;;
    'output = '*)     ofile=${line#output = } ;;
    'data-binary = '*) payload=${line#data-binary = } ;;
    'max-time = '*)   maxtime=${line#max-time = } ;;
  esac
done < "$cfg"
strip_quotes() { local v=$1; v=${v#\"}; v=${v%\"}; printf '%s' "$v"; }
url=$(strip_quotes "$url")
ofile=$(strip_quotes "$ofile")
payload=$(strip_quotes "$payload")
payload=${payload#@}

# https://host/bot<TOKEN>/<method>
rest=${url#*/bot}
token=${rest%%/*}
method=${rest#*/}
printf '%s\n' "$token" >> "$state/token-seen.log"

long_poll=-
[ -n "$payload" ] && [ -f "$payload" ] && long_poll=$(jq -r '.timeout // "-"' "$payload")
printf '%s max-time=%s timeout=%s\n' "$method" "${maxtime:--}" "$long_poll" >> "$state/budget.log"

case "$method" in
  getUpdates)
    offset=0
    [ -n "$payload" ] && [ -f "$payload" ] && offset=$(jq -r '.offset // 0' "$payload")
    case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
    printf '%s %s\n' "$method" "$offset" >> "$state/calls.log"
    if [ -n "${FAKE_TG_BODY_OVERRIDE:-}" ]; then
      [ -n "$ofile" ] && printf '%s' "$FAKE_TG_BODY_OVERRIDE" > "$ofile"
      printf '%s' "${FAKE_TG_GETUPDATES_CODE:-200}"
      exit 0
    fi
    code=${FAKE_TG_GETUPDATES_CODE:-200}
    if [ "$code" != 200 ]; then
      [ -n "$ofile" ] && printf '%s' '{"ok":false}' > "$ofile"
      printf '%s' "$code"
      exit 0
    fi
    # Real Bot API semantics: confirming an offset deletes everything below it.
    if [ "$offset" -gt 0 ]; then
      jq -c --argjson o "$offset" '[.[] | select(.update_id >= $o)]' \
        "$state/updates.json" > "$state/updates.json.tmp" \
        && mv -f "$state/updates.json.tmp" "$state/updates.json"
    fi
    limit=25
    [ -n "$payload" ] && [ -f "$payload" ] && limit=$(jq -r '.limit // 25' "$payload")
    case "$limit" in ''|*[!0-9]*) limit=25 ;; esac
    [ -n "$ofile" ] && jq -c --argjson o "$offset" --argjson n "$limit" \
      '{ok:true, result: [.[] | select(.update_id >= $o)] | sort_by(.update_id) | .[0:$n]}' \
      "$state/updates.json" > "$ofile"
    printf '200'
    ;;
  sendMessage)
    printf '%s -\n' "$method" >> "$state/calls.log"
    code=${FAKE_TG_SENDMESSAGE_CODE:-200}
    if [ -n "${FAKE_TG_SEND_FAIL_FROM:-}" ]; then
      delivered=$(wc -l < "$state/sent.jsonl" | tr -d '[:space:]')
      [ -n "$delivered" ] || delivered=0
      if [ "$(( delivered + 1 ))" -ge "$FAKE_TG_SEND_FAIL_FROM" ]; then
        code=500
      fi
    fi
    if [ "$code" = 200 ]; then
      [ -n "$payload" ] && [ -f "$payload" ] && jq -c '.' "$payload" >> "$state/sent.jsonl"
      [ -n "$ofile" ] && printf '%s' '{"ok":true}' > "$ofile"
    else
      [ -n "$ofile" ] && printf '%s' '{"ok":false}' > "$ofile"
    fi
    printf '%s' "$code"
    ;;
  *)
    printf '%s -\n' "$method" >> "$state/calls.log"
    [ -n "$ofile" ] && printf '%s' '{"ok":false}' > "$ofile"
    printf '404'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
}

# tg_queue <update_id> <chat_id> <user_id> <text>: queue a plain private text
# message from a non-bot sender.
tg_queue() {
  local uid=$1 chat=$2 user=$3 text=$4
  tg_queue_json "$(jq -cn --argjson uid "$uid" --argjson chat "$chat" --argjson user "$user" \
    --arg text "$text" \
    '{update_id:$uid, message:{message_id:($uid*10), date:1750000000,
      from:{id:$user, is_bot:false, first_name:"Paired"},
      chat:{id:$chat, type:"private"}, text:$text}}')"
}

# tg_queue_json <update-json>: queue an arbitrary update object verbatim, for the
# chat types, senders, and payload shapes the bridge must refuse or classify.
tg_queue_json() {
  local update=$1
  jq -c --argjson u "$update" '. + [$u]' "$FAKE_TG_DIR/updates.json" \
    > "$FAKE_TG_DIR/updates.json.tmp"
  mv -f "$FAKE_TG_DIR/updates.json.tmp" "$FAKE_TG_DIR/updates.json"
}

# tg_sent_count: how many messages the server actually delivered.
tg_sent_count() {
  local n
  n=$(wc -l < "$FAKE_TG_DIR/sent.jsonl" | tr -d '[:space:]')
  printf '%s' "${n:-0}"
}

# tg_sent_text <index>: the text of the Nth delivered message (1-based).
tg_sent_text() {
  sed -n "$1p" "$FAKE_TG_DIR/sent.jsonl" | jq -r '.text'
}

# tg_home <root> <name> [token]: build a firstmate home with a .env carrying a
# bot token, and echo its path. Pass "" as the token for an unconfigured home.
tg_home() {
  local root=$1 name=$2 token=${3-1234567890:AAHfake-test-token-not-a-real-one} home
  home="$root/$name"
  mkdir -p "$home/state" "$home/config" "$home/data"
  if [ -n "$token" ]; then
    printf 'FM_TELEGRAM_BOT_TOKEN=%s\n' "$token" > "$home/.env"
  fi
  printf '%s\n' "$home"
}
