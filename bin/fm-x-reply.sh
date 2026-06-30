#!/usr/bin/env bash
# Post firstmate's composed answer back to the relay for a pending X mention.
#
# Usage: fm-x-reply.sh <request_id> [--image <path>] <text>
#        fm-x-reply.sh <request_id> [--image <path>] --text-file <path>
#        fm-x-reply.sh <request_id> [--image <path>] -
#        fm-x-reply.sh <request_id> --followup [--image <path>] ...
#
# The --text-file / stdin forms exist so a caller never has to inline reply text
# (which may be influenced by a public mention) into a shell command, where shell
# expansion or quote-breakage could bite. fmx-respond uses them; the positional
# <text> form is kept for back-compat and tests.
#
# Optional --image <path> attaches one local image file to the answer or followup
# POST body as {media_type,data_base64}. Supported extension mapping includes
# PNG, JPEG, GIF, WebP, BMP, and TIFF. If long text becomes a thread, the relay
# attaches that image to the first/opener tweet only.
#
# Two endpoints, one client. By default the reply is the single answer to a
# mention, POSTed to $RELAY/connector/answer. With --followup it is instead the
# ONE later "done - here's the result" reply for a mention that spawned real
# work, POSTed to $RELAY/connector/followup; the relay retains the
# request->tweet binding for a 24h window after the initial answer and accepts a
# single thread-bound follow-up. --followup may appear anywhere after the
# request_id; everything else (thread-split, payload shape, dry-run, never-inline
# safety) is identical, so only the endpoint and the dry-run marker differ.
#
# POSTs to $RELAY/connector/<answer|followup> with the bearer token. The relay
# binds the reply to the exact tweet it recorded for that request_id, so this
# client only ever echoes the relay-issued request_id and NEVER names a tweet id.
# On success it echoes ONLY that request_id; on a non-2xx (or transport failure)
# it exits non-zero so the caller knows the post did not land.
#
# Long replies auto-split into a numbered thread (premium-independent: each tweet
# stays within FMX_X_REPLY_MAX_CHARS, default 280). A reply that fits in one tweet
# sends {request_id, text}; a thread sends {request_id, text, texts:[chunk,...]}
# where `texts` is the ordered "(k/n)" chunks for the relay to post as chained
# replies, and `text` is the first chunk so a relay that only reads `text` still
# posts the opener. If --image is present, the relay attaches it to this opener.
# At most FMX_X_THREAD_MAX tweets (default 25) are produced.
#
# Live post config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN
# (required), FMX_RELAY_URL (default https://myfirstmate.io). Auth:
# Authorization: Bearer <token>.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), the reply is NOT posted.
# Instead the would-be POST body ({request_id, text}, or {request_id, text,
# texts} for a thread) is recorded to state/x-outbox/<request_id>.json and a "DRY
# RUN" summary is printed to stderr; stdout still echoes the request_id and the
# exit is 0, so the loop runs end to end without a public tweet. A follow-up
# dry-run additionally carries an "endpoint":"followup" marker in the recorded
# body so a preview is self-describing; the live POST body is unchanged. With
# --image, the dry-run record replaces image bytes with a compact image marker
# {media_type,bytes,source_path}, not the base64 bytes. Dry-run needs neither a
# token nor the relay.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

TMP_FILES=()
cleanup_tmp_files() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup_tmp_files EXIT

reply_make_tmp_file() {
  local var_name=$1 file
  file=$(mktemp "${TMPDIR:-/tmp}/fm-x-reply.XXXXXX") || return 1
  TMP_FILES+=("$file")
  printf -v "$var_name" '%s' "$file"
}

usage() {
  echo "usage: fm-x-reply.sh <request_id> [--followup] [--image <path>] <text> | [--followup] [--image <path>] --text-file <path> | [--followup] [--image <path>] -" >&2
}

help() {
  cat <<'EOF'
usage: fm-x-reply.sh <request_id> [--followup] [--image <path>] <text>
       fm-x-reply.sh <request_id> [--followup] [--image <path>] --text-file <path>
       fm-x-reply.sh <request_id> [--followup] [--image <path>] -

Post a public-safe X answer to the relay, or a completion follow-up with --followup.

Options:
  --followup       POST to /connector/followup instead of /connector/answer.
  --image <path>   Attach one local image file; threaded replies attach it to the opener tweet.
  --text-file <path>
                   Read reply text from a file instead of the command line.
  -                Read reply text from stdin.
  --help           Show this help.
EOF
}

case "${1:-}" in
  --help|-h) help; exit 0 ;;
esac

REQ=${1:-}
if [ -z "$REQ" ]; then
  usage
  exit 2
fi
shift

# --followup selects the relay's /connector/followup endpoint instead of
# /connector/answer; it may appear anywhere after the request_id, so strip it out
# along with --image and process the remaining args (the text source) exactly as
# the answer path always has.
FOLLOWUP=0
IMAGE_PATH=
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --followup) FOLLOWUP=1 ;;
    --image)
      shift
      if [ "$#" -lt 1 ] || [ -z "$1" ]; then
        echo "fm-x-reply: missing --image path" >&2
        usage
        exit 2
      fi
      IMAGE_PATH=$1
      ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
if [ "${#ARGS[@]}" -lt 1 ]; then
  usage
  exit 2
fi
set -- "${ARGS[@]}"

case "$1" in
  --text-file)
    if [ "$#" -lt 2 ]; then
      echo "usage: fm-x-reply.sh <request_id> [--followup] [--image <path>] --text-file <path>" >&2
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

# The endpoint is the only behavioral difference between an answer and a
# follow-up; everything below (split, payload, dry-run, post) is shared.
if [ "$FOLLOWUP" = 1 ]; then
  ENDPOINT=followup
else
  ENDPOINT=answer
fi

fmx_load_config

# The request_id becomes a filename (inbox/outbox record), so never trust it into
# a path even though the relay issues it.
case "$REQ" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-reply: unsafe request_id: $REQ" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-x-reply: jq not found" >&2; exit 1; }

IMAGE_PAYLOAD_FILE=
IMAGE_PREVIEW=
PAYLOAD_FILE=
if [ -n "$IMAGE_PATH" ]; then
  reply_make_tmp_file IMAGE_PAYLOAD_FILE || {
    echo "fm-x-reply: cannot create image payload temp file" >&2; exit 1; }
  IMAGE_PREVIEW=$(fmx_image_payload_file "$IMAGE_PATH" fm-x-reply "$IMAGE_PAYLOAD_FILE") || exit 1
  printf '%s' "$IMAGE_PREVIEW" | jq -e . >/dev/null 2>&1 || {
    echo "fm-x-reply: failed to build image preview" >&2; exit 1; }
fi

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

# Build the body with jq so the text and optional image object are correctly
# JSON-escaped. A single tweet sends {request_id, text}; a thread also sends
# {texts: [...]} for the relay to post as chained replies. When image is present
# on a thread, the relay attaches it to the first chunk only.
reply_make_tmp_file PAYLOAD_FILE || {
  echo "fm-x-reply: cannot create request payload temp file" >&2; exit 1; }
if [ -n "$IMAGE_PAYLOAD_FILE" ]; then
  fmx_reply_payload_json "$REQ" "$CHUNKS" "$N" "$IMAGE_PAYLOAD_FILE" > "$PAYLOAD_FILE" || {
    echo "fm-x-reply: failed to build request payload" >&2; exit 1; }
else
  fmx_reply_payload_json "$REQ" "$CHUNKS" "$N" > "$PAYLOAD_FILE" || {
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
  # The recorded body is the would-be POST body, except image bytes are replaced
  # by a compact marker. A follow-up preview additionally carries an
  # "endpoint":"followup" marker so an outbox record is self-describing.
  OUTREC=$(fmx_reply_outbox_json "$REQ" "$CHUNKS" "$N" "$FOLLOWUP" "$IMAGE_PREVIEW") || {
    echo "fm-x-reply: failed to build dry-run outbox record" >&2; exit 1; }
  printf '%s\n' "$OUTREC" > "$outbox_file" 2>/dev/null || {
    echo "fm-x-reply: cannot write dry-run outbox: $outbox_file" >&2
    exit 1
  }
  if [ "$N" -le 1 ]; then
    printf 'fm-x-reply: DRY RUN - would POST to %s/connector/%s (recorded: state/x-outbox/%s.json): %s\n' \
      "$FMX_RELAY" "$ENDPOINT" "$REQ" "$(printf '%s' "$CHUNKS" | jq -r '.[0]')" >&2
  else
    printf 'fm-x-reply: DRY RUN - would POST a %s-tweet thread to %s/connector/%s (recorded: state/x-outbox/%s.json):\n' \
      "$N" "$FMX_RELAY" "$ENDPOINT" "$REQ" >&2
    printf '%s' "$CHUNKS" | jq -r '.[]' | while IFS= read -r __chunk; do printf '  %s\n' "$__chunk" >&2; done
  fi
  printf '%s\n' "$REQ"
  exit 0
fi

if [ -z "$FMX_TOKEN" ]; then
  echo "fm-x-reply: X mode not configured (no FMX_PAIRING_TOKEN)" >&2
  exit 1
fi
code=$(fmx_post_json "$ENDPOINT" "$PAYLOAD_FILE")
post_rc=$?
case "$post_rc" in
  0) : ;;
  127) echo "fm-x-reply: curl not found" >&2; exit 1 ;;
  3) echo "fm-x-reply: invalid FMX_PAIRING_TOKEN" >&2; exit 1 ;;
  *) echo "fm-x-reply: request to relay failed" >&2; exit 1 ;;
esac

case "$code" in
  2[0-9][0-9]) printf '%s\n' "$REQ" ;;
  *) echo "fm-x-reply: relay returned HTTP $code" >&2; exit 1 ;;
esac
