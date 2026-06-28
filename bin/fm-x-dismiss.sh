#!/usr/bin/env bash
# Dismiss a pending X mention at the relay WITHOUT replying to it.
#
# Usage: fm-x-dismiss.sh <request_id>
#
# When firstmate decides NOT to reply to a mention (a pure acknowledgment, or any
# mention it judges not worth a reply), clearing only the local inbox file is not
# enough: the relay keeps re-offering that request on every poll until it times
# out to a polite "offline" auto-reply. Dismiss tells the relay to drop the
# request outright - it posts nothing and stops re-offering it - so a skipped
# mention causes no re-offer churn and no offline auto-reply.
#
# POSTs {"request_id":"<id>"} (no text - a dismiss has no body) to
# $RELAY/connector/dismiss with the bearer token. On success (2xx) it echoes ONLY
# the request_id; on a non-2xx (or transport failure) it exits non-zero so the
# caller knows the dismiss did not land and can fall back to leaving the inbox
# file for a later pass.
#
# Live post config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN
# (required), FMX_RELAY_URL (default https://myfirstmate.io). Auth:
# Authorization: Bearer <token>.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), nothing is posted. Instead the
# would-be POST body ({request_id}) is recorded to state/x-outbox/<request_id>.json
# with an "endpoint":"dismiss" marker so the preview is self-describing (the live
# POST body stays {request_id}), a "DRY RUN" summary is printed to stderr, and
# stdout still echoes the request_id with exit 0. Dry-run needs neither a token
# nor the relay.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

usage() {
  echo "usage: fm-x-dismiss.sh <request_id>" >&2
}

REQ=${1:-}
if [ -z "$REQ" ] || [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

fmx_load_config

# The request_id becomes a filename (inbox/outbox record), so never trust it into
# a path even though the relay issues it.
case "$REQ" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-dismiss: unsafe request_id: $REQ" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-x-dismiss: jq not found" >&2; exit 1; }

# Build the body with jq so the request_id is correctly JSON-escaped. This is
# exactly what would be POSTed (and, in dry-run, exactly what we record/preview):
# a dismiss carries only {request_id}.
PAYLOAD=$(jq -cn --arg rid "$REQ" '{request_id:$rid}') || {
  echo "fm-x-dismiss: failed to build request payload" >&2; exit 1; }

# Preview / dry-run: surface what we WOULD post and stop, without auth or network.
if [ -n "$FMX_DRY" ]; then
  outbox_dir="$STATE/x-outbox"
  outbox_file="$outbox_dir/$REQ.json"
  mkdir -p "$outbox_dir" 2>/dev/null || {
    echo "fm-x-dismiss: cannot create dry-run outbox: $outbox_dir" >&2
    exit 1
  }
  # The recorded body carries an "endpoint":"dismiss" marker so an outbox record
  # is self-describing (the live POST body stays exactly {request_id}).
  OUTREC=$(printf '%s' "$PAYLOAD" | jq -c '. + {endpoint:"dismiss"}') || {
    echo "fm-x-dismiss: failed to build dry-run outbox record" >&2; exit 1; }
  printf '%s\n' "$OUTREC" > "$outbox_file" 2>/dev/null || {
    echo "fm-x-dismiss: cannot write dry-run outbox: $outbox_file" >&2
    exit 1
  }
  printf 'fm-x-dismiss: DRY RUN - would POST to %s/connector/dismiss (recorded: state/x-outbox/%s.json)\n' \
    "$FMX_RELAY" "$REQ" >&2
  printf '%s\n' "$REQ"
  exit 0
fi

if [ -z "$FMX_TOKEN" ]; then
  echo "fm-x-dismiss: X mode not configured (no FMX_PAIRING_TOKEN)" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "fm-x-dismiss: curl not found" >&2; exit 1; }
AUTH_HEADER_FILE=$(fmx_auth_header_file) || {
  echo "fm-x-dismiss: invalid FMX_PAIRING_TOKEN" >&2
  exit 1
}
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT

code=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Content-Type: application/json' \
  --data "$PAYLOAD" \
  "$FMX_RELAY/connector/dismiss" 2>/dev/null) || {
  echo "fm-x-dismiss: request to relay failed" >&2
  exit 1
}

case "$code" in
  2[0-9][0-9]) printf '%s\n' "$REQ" ;;
  *) echo "fm-x-dismiss: relay returned HTTP $code" >&2; exit 1 ;;
esac
