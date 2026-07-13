#!/usr/bin/env bash
# Post firstmate's composed answer back to the relay for a pending X-mode mention.
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
# attaches that image to the first/opener message only.
#
# Two endpoints, one client. By default the reply is the single answer to a
# mention, POSTed to $RELAY/connector/answer. With --followup it is instead one
# of up to three later "here's where things stand" replies for a mention that
# spawned real work, POSTed to $RELAY/connector/followup; the relay retains the
# request binding for a 7-day window after the initial answer and accepts up to
# three thread-bound follow-ups against it. --followup may appear
# anywhere after the request_id; everything else (thread-split, payload shape,
# dry-run, never-inline safety) is identical, so only the endpoint and the
# dry-run marker differ.
#
# POSTs to $RELAY/connector/<answer|followup> with the bearer token. The relay
# binds the reply to the exact post it recorded for that request_id, so this
# client only ever echoes the relay-issued request_id and NEVER names a platform
# message id.
# On success it echoes ONLY that request_id; on a non-2xx (or transport failure)
# it exits non-zero so the caller knows the post did not land. The confirmed
# relay contract for an exhausted follow-up binding is HTTP 409 from
# /connector/followup, optionally with {"error":"followup_unavailable"} in the
# response body. This client always maps a follow-up 409 to exit code 9 so
# fm-x-followup.sh can tell "exhausted binding" apart from a transient post
# failure worth retrying; the body marker only sharpens the diagnostic. That
# relay-side 409 is secondary: after the relay's own cleanup sweep, a very-late
# call can instead see a benign no-op 200, so fm-x-followup.sh's local
# window/cap pruning remains the primary guard.
#
# Reply platform + split budget are resolved per axis: an explicit
# FMX_REPLY_PLATFORM / FMX_REPLY_MAX_CHARS env override wins (fm-x-followup passes
# recorded task-link context this way); otherwise resolution runs the durable
# per-request context registry -> the still-present inbox payload -> an
# authoritative relay lookup by request_id (fm-x-lib.sh:fmx_resolve_reply_context).
# The relay step is confined to a live follow-up so the answer path and every
# dry-run stay network-free. This is what keeps a delayed request-id follow-up on
# the ORIGINAL platform's budget even after the inbox is drained and with no task
# link surviving. FAIL-SAFE: if a --followup reply's platform/budget cannot be
# authoritatively resolved, this REFUSES with exit 8 (distinct from the 409 exit
# 9) rather than posting with a locally defaulted budget - firstmate holds and
# retries it.
#
# Long replies auto-split into a numbered thread. X stays within
# FMX_X_REPLY_MAX_CHARS, default 280. Discord uses
# FMX_DISCORD_REPLY_MAX_CHARS, default 1900, safely below Discord's 2000
# character message limit. A reply that fits in one message sends
# {request_id, text}; a thread sends {request_id, text, texts:[chunk,...]} where
# `texts` is the ordered "(k/n)" chunks for the relay to post as chained replies,
# and `text` is the first chunk so a relay that only reads `text` still posts the
# opener. If --image is present, the relay attaches it to this opener. At most
# FMX_X_THREAD_MAX messages (default 25) are produced.
#
# Live post config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN
# (required), FMX_RELAY_URL (default https://myfirstmate.io). Auth:
# Authorization: Bearer <token>.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), the reply is NOT posted.
# Instead the would-be POST body ({request_id, text}, or {request_id, text,
# texts} for a thread) is recorded to state/x-outbox/<request_id>.json and a "DRY
# RUN" summary is printed to stderr; stdout still echoes the request_id and the
# exit is 0, so the loop runs end to end without a public post. A follow-up
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

Post a public-safe X-mode answer to the relay, or a completion follow-up with --followup.

Options:
  --followup       POST to /connector/followup instead of /connector/answer.
  --image <path>   Attach one local image file; threaded replies attach it to the opener tweet or message.
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

# Resolve the reply platform + split budget. An explicit env override wins per
# axis (fm-x-followup passes recorded task-link context this way); otherwise
# resolve through the durable per-request context registry, then the still-present
# inbox payload, then - for a follow-up posted live by request_id after the inbox
# has been drained - an AUTHORITATIVE relay lookup. The relay step is confined to
# the follow-up path so the answer path and every dry-run stay network-free
# (fm-x-lib.sh owns the resolution-order contract).
ALLOW_RELAY=0
if [ -n "${FMX_REPLY_PLATFORM:-}" ] && [ -n "${FMX_REPLY_MAX_CHARS:-}" ]; then
  REQ_PLATFORM=${FMX_REPLY_PLATFORM}
  REQ_EXPLICIT_MAX=${FMX_REPLY_MAX_CHARS}
else
  if [ "$FOLLOWUP" = 1 ] && [ -z "$FMX_DRY" ] && [ -n "$FMX_TOKEN" ]; then
    ALLOW_RELAY=1
  fi
  REPLY_CONTEXT=$(fmx_resolve_reply_context "$STATE" "$REQ" "$ALLOW_RELAY") || {
    echo "fm-x-reply: failed to resolve request platform context" >&2
    exit 1
  }
  REQ_PLATFORM=${FMX_REPLY_PLATFORM:-$(printf '%s' "$REPLY_CONTEXT" | jq -r '.platform // ""')}
  REQ_EXPLICIT_MAX=${FMX_REPLY_MAX_CHARS:-$(printf '%s' "$REPLY_CONTEXT" | jq -r '.reply_max_chars // ""')}
fi
case "$REQ_PLATFORM" in
  discord|x|'') ;;
  twitter) REQ_PLATFORM=x ;;
  *) REQ_PLATFORM= ;;
esac
case "$REQ_EXPLICIT_MAX" in
  ''|*[!0-9]*) REQ_EXPLICIT_MAX= ;;
esac
# Was the platform/budget authoritatively resolved by any source (override,
# registry, inbox, or relay)? Drives the follow-up fail-safe below.
CONTEXT_RESOLVED=0
if [ -n "$REQ_PLATFORM" ] && [ -n "$REQ_EXPLICIT_MAX" ]; then
  CONTEXT_RESOLVED=1
fi

if [ "$FOLLOWUP" = 1 ] && [ "$CONTEXT_RESOLVED" = 0 ]; then
  relay_note=
  [ "$ALLOW_RELAY" = 1 ] && relay_note=", and the relay did not supply the missing value by request_id"
  printf 'fm-x-reply: refusing follow-up for %s: could not authoritatively determine both the reply platform and explicit budget (local per-request context was incomplete%s). Hold and retry once both values are recoverable.\n' \
    "$REQ" "$relay_note" >&2
  exit 8
fi
REPLY_MAX=$(fmx_reply_limit_for_platform "$REQ_PLATFORM" "$REQ_EXPLICIT_MAX")

IMAGE_PAYLOAD_FILE=
IMAGE_PREVIEW=
PAYLOAD_FILE=
RESPONSE_BODY_FILE=
if [ -n "$IMAGE_PATH" ]; then
  reply_make_tmp_file IMAGE_PAYLOAD_FILE || {
    echo "fm-x-reply: cannot create image payload temp file" >&2; exit 1; }
  IMAGE_PREVIEW=$(fmx_image_payload_file "$IMAGE_PATH" fm-x-reply "$IMAGE_PAYLOAD_FILE") || exit 1
  printf '%s' "$IMAGE_PREVIEW" | jq -e . >/dev/null 2>&1 || {
    echo "fm-x-reply: failed to build image preview" >&2; exit 1; }
fi

# Auto-split a long reply into a numbered thread using the target platform's
# per-message budget. A reply that fits in one message stays single and
# unnumbered.
CHUNKS=$(printf '%s' "$TEXT" | fmx_split_thread "$REPLY_MAX" "$FMX_THREAD_MAX") || {
  echo "fm-x-reply: failed to split reply into a thread" >&2
  exit 1
}
N=$(printf '%s' "$CHUNKS" | jq 'length' 2>/dev/null) || N=
case "$N" in ''|*[!0-9]*) echo "fm-x-reply: failed to split reply into a thread" >&2; exit 1 ;; esac
[ "$N" -gt 0 ] || { echo "fm-x-reply: empty reply text" >&2; exit 2; }

# Build the body with jq so the text and optional image object are correctly
# JSON-escaped. A single message sends {request_id, text}; a thread also sends
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
reply_make_tmp_file RESPONSE_BODY_FILE || {
  echo "fm-x-reply: cannot create relay response temp file" >&2; exit 1; }
code=$(fmx_post_json "$ENDPOINT" "$PAYLOAD_FILE" "$RESPONSE_BODY_FILE")
post_rc=$?
case "$post_rc" in
  0) : ;;
  127) echo "fm-x-reply: curl not found" >&2; exit 1 ;;
  3) echo "fm-x-reply: invalid FMX_PAIRING_TOKEN" >&2; exit 1 ;;
  *) echo "fm-x-reply: request to relay failed" >&2; exit 1 ;;
esac

case "$code" in
  2[0-9][0-9])
    if [ "$FOLLOWUP" = 0 ]; then
      fmx_context_registry_set "$STATE" "$REQ" "$REQ_PLATFORM" "$REQ_EXPLICIT_MAX" 1 2>/dev/null \
        || echo "fm-x-reply: warning: could not retain reply context for $REQ" >&2
    fi
    printf '%s\n' "$REQ"
    ;;
  409)
    if [ "$FOLLOWUP" = 1 ]; then
      if [ -s "$RESPONSE_BODY_FILE" ] && {
        jq -e '.error == "followup_unavailable"' "$RESPONSE_BODY_FILE" >/dev/null 2>&1 ||
          grep -F 'followup_unavailable' "$RESPONSE_BODY_FILE" >/dev/null 2>&1
      }; then
        echo "fm-x-reply: relay rejected the follow-up (confirmed followup_unavailable marker): HTTP 409" >&2
      else
        echo "fm-x-reply: relay rejected the follow-up (HTTP 409 cap/window exhaustion; marker absent)" >&2
      fi
      exit 9
    fi
    echo "fm-x-reply: relay returned HTTP $code" >&2
    exit 1
    ;;
  *) echo "fm-x-reply: relay returned HTTP $code" >&2; exit 1 ;;
esac
