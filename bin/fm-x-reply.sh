#!/usr/bin/env bash
# Post firstmate's composed answer back to the relay for a pending X mention.
#
# Usage: fm-x-reply.sh <request_id> <text>
#        fm-x-reply.sh <request_id> --text-file <path>   # read the reply from a file
#        fm-x-reply.sh <request_id> -                    # read the reply from stdin
#
# The --text-file / stdin forms exist so a caller never has to inline reply text
# (which may be influenced by a public mention) into a shell command, where shell
# expansion or quote-breakage could bite. fmx-respond uses them; the positional
# <text> form is kept for back-compat and tests.
#
# POSTs to $RELAY/connector/answer with the bearer token. The relay binds the
# reply to the exact tweet it recorded for that request_id, so this client only
# ever echoes the relay-issued request_id and NEVER names a tweet id. On success
# it echoes ONLY that request_id; on a non-2xx (or transport failure) it exits
# non-zero so the caller knows the post did not land.
#
# Long replies auto-split into a numbered thread (premium-independent: each tweet
# stays within FMX_X_REPLY_MAX_CHARS, default 280). A reply that fits in one tweet
# sends {request_id, text}; a thread sends {request_id, text, texts:[chunk,...]}
# where `texts` is the ordered "(k/n)" chunks for the relay to post as chained
# replies, and `text` is the first chunk so a relay that only reads `text` still
# posts the opener. At most FMX_X_THREAD_MAX tweets (default 25) are produced.
#
# Live post config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN
# (required), FMX_RELAY_URL (default https://myfirstmate.io). Auth:
# Authorization: Bearer <token>.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), the reply is NOT posted.
# Instead the full would-be POST body ({request_id, text}, or {request_id, text,
# texts} for a thread) is recorded to state/x-outbox/<request_id>.json and a
# "DRY RUN" summary is printed to stderr; stdout still echoes the request_id and
# the exit is 0, so the loop runs end to end without a public tweet. Dry-run
# needs neither a token nor the relay.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

REQ=${1:-}
if [ -z "$REQ" ] || [ "$#" -lt 2 ]; then
  echo "usage: fm-x-reply.sh <request_id> <text> | <request_id> --text-file <path> | <request_id> -" >&2
  exit 2
fi
shift
case "$1" in
  --text-file)
    if [ "$#" -lt 2 ]; then
      echo "usage: fm-x-reply.sh <request_id> --text-file <path>" >&2
      exit 2
    fi
    TEXT=$(cat -- "$2") || { echo "fm-x-reply: cannot read text file: $2" >&2; exit 1; }
    ;;
  -)
    TEXT=$(cat)
    ;;
  *)
    TEXT=$1
    ;;
esac
if [ -z "$TEXT" ]; then
  echo "fm-x-reply: empty reply text" >&2
  exit 2
fi

fmx_load_config

# The request_id becomes a filename (inbox/outbox record), so never trust it into
# a path even though the relay issues it.
case "$REQ" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-reply: unsafe request_id: $REQ" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-x-reply: jq not found" >&2; exit 1; }

# Auto-split a long reply into a numbered thread (premium-independent: each tweet
# stays within the per-tweet budget). A reply that fits in one tweet stays a
# single, unnumbered tweet.
CHUNKS=$(printf '%s' "$TEXT" | fmx_split_thread "$FMX_MAX" "$FMX_THREAD_MAX") || {
  echo "fm-x-reply: failed to split reply into a thread" >&2
  exit 1
}
N=$(printf '%s' "$CHUNKS" | jq 'length' 2>/dev/null) || N=
case "$N" in ''|*[!0-9]*) echo "fm-x-reply: failed to split reply into a thread" >&2; exit 1 ;; esac
[ "$N" -gt 0 ] || { echo "fm-x-reply: empty reply text" >&2; exit 2; }

# Build the body with jq so the text is correctly JSON-escaped. This is exactly
# what would be POSTed (and, in dry-run, exactly what we record/preview). A
# single tweet sends {request_id, text}; a thread also sends {texts: [...]} (the
# ordered chunks) for the relay to post as chained replies, keeping `text` as the
# first chunk so a relay that only understands `text` still posts the opener.
if [ "$N" -le 1 ]; then
  PAYLOAD=$(printf '%s' "$CHUNKS" | jq -c --arg rid "$REQ" '{request_id:$rid, text:(.[0] // "")}') || {
    echo "fm-x-reply: failed to build request payload" >&2; exit 1; }
else
  PAYLOAD=$(printf '%s' "$CHUNKS" | jq -c --arg rid "$REQ" '{request_id:$rid, text:.[0], texts:.}') || {
    echo "fm-x-reply: failed to build request payload" >&2; exit 1; }
fi

# Preview / dry-run: surface what we WOULD post and stop, without auth or network.
if [ -n "$FMX_DRY" ]; then
  outbox_dir="$STATE/x-outbox"
  outbox_file="$outbox_dir/$REQ.json"
  mkdir -p "$outbox_dir" 2>/dev/null || {
    echo "fm-x-reply: cannot create dry-run outbox: $outbox_dir" >&2
    exit 1
  }
  printf '%s\n' "$PAYLOAD" > "$outbox_file" 2>/dev/null || {
    echo "fm-x-reply: cannot write dry-run outbox: $outbox_file" >&2
    exit 1
  }
  if [ "$N" -le 1 ]; then
    printf 'fm-x-reply: DRY RUN - would POST to %s/connector/answer (recorded: state/x-outbox/%s.json): %s\n' \
      "$FMX_RELAY" "$REQ" "$(printf '%s' "$CHUNKS" | jq -r '.[0]')" >&2
  else
    printf 'fm-x-reply: DRY RUN - would POST a %s-tweet thread to %s/connector/answer (recorded: state/x-outbox/%s.json):\n' \
      "$N" "$FMX_RELAY" "$REQ" >&2
    printf '%s' "$CHUNKS" | jq -r '.[]' | while IFS= read -r __chunk; do printf '  %s\n' "$__chunk" >&2; done
  fi
  printf '%s\n' "$REQ"
  exit 0
fi

if [ -z "$FMX_TOKEN" ]; then
  echo "fm-x-reply: X mode not configured (no FMX_PAIRING_TOKEN)" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "fm-x-reply: curl not found" >&2; exit 1; }
AUTH_HEADER_FILE=$(fmx_auth_header_file) || {
  echo "fm-x-reply: invalid FMX_PAIRING_TOKEN" >&2
  exit 1
}
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT

code=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Content-Type: application/json' \
  --data "$PAYLOAD" \
  "$FMX_RELAY/connector/answer" 2>/dev/null) || {
  echo "fm-x-reply: request to relay failed" >&2
  exit 1
}

case "$code" in
  2[0-9][0-9]) printf '%s\n' "$REQ" ;;
  *) echo "fm-x-reply: relay returned HTTP $code" >&2; exit 1 ;;
esac
