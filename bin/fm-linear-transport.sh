#!/usr/bin/env bash
# fm-linear-transport.sh - the default Linear GraphQL transport.
#
# This is the ONLY place in firstmate that talks to Linear over the network, and
# the only place a Linear credential is read for use. Splitting it out is what
# makes the whole synchronization path testable with no credential and no
# network: bin/fm-linear-sync.sh calls a transport through this exact contract,
# and FM_LINEAR_TRANSPORT can point it at a hermetic fake instead.
#
# Usage:
#   fm-linear-transport.sh <request-json-file> <response-body-out-file>
#
# Contract every transport must satisfy:
#   - stdin is not read; the request body is the file at $1, a complete GraphQL
#     document object: {"query": "...", "variables": {...}}
#   - the response body is written to the file at $2
#   - the HTTP status code is printed to stdout, alone, with no trailing text
#   - exit 0 means the exchange completed and $2 plus the printed code are
#     authoritative; a non-zero exit means the exchange did NOT complete and the
#     caller must treat the delivery as still pending, never as failed-and-done
#   - the request body never carries a credential, so it is safe to log
#
# Exit status:
#   0  exchange completed (any HTTP code)
#   3  local precondition failed: no curl, or no usable credential
#   4  the request never completed (timeout, DNS, connection failure)
#   2  usage
#
# Secret handling: the API key is written to a mode-0600 temp file as a complete
# header line and handed to curl as `-H @file`. It never appears in argv, in an
# environment variable curl inherits by name, in the request body, or in any
# output this script produces. The temp file is removed on every exit path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

case "${1-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 2 ] || { usage; exit 2; }
REQUEST=$1
RESPONSE=$2

[ -f "$REQUEST" ] && [ ! -L "$REQUEST" ] || {
  echo "fm-linear-transport: request file is missing or not a plain file: $REQUEST" >&2
  exit 2
}

command -v curl >/dev/null 2>&1 || {
  echo "fm-linear-transport: curl is required to reach Linear" >&2
  exit 3
}

if ! fm_linear_config_load "$FM_HOME"; then
  printf 'fm-linear-transport: %s\n' "$FM_LINEAR_CONFIG_ERROR" >&2
  exit 3
fi

AUTH_HEADER_FILE=
cleanup() {
  [ -z "$AUTH_HEADER_FILE" ] || rm -f -- "$AUTH_HEADER_FILE"
}
trap cleanup EXIT

AUTH_HEADER_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-linear-auth.XXXXXX") || {
  echo "fm-linear-transport: cannot create a private credential file" >&2
  exit 3
}
chmod 600 "$AUTH_HEADER_FILE" 2>/dev/null || {
  echo "fm-linear-transport: cannot secure the credential file" >&2
  exit 3
}
# The credential is used verbatim as the Authorization value. Linear personal
# API keys are sent bare and OAuth access tokens are sent as "Bearer <token>",
# so an operator pastes whichever their workspace issued and this side never
# has to guess which scheme it holds.
printf 'Authorization: %s\n' "$FM_LINEAR_API_KEY" > "$AUTH_HEADER_FILE" || {
  echo "fm-linear-transport: cannot write the credential file" >&2
  exit 3
}

: > "$RESPONSE" 2>/dev/null || {
  echo "fm-linear-transport: cannot write the response file: $RESPONSE" >&2
  exit 2
}

CODE=$(curl -m "${FM_LINEAR_HTTP_TIMEOUT:-20}" -s -o "$RESPONSE" -w '%{http_code}' \
  -X POST \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-binary "@$REQUEST" \
  "$FM_LINEAR_API_URL" 2>/dev/null) || {
  echo "fm-linear-transport: the request to Linear did not complete" >&2
  exit 4
}

case "$CODE" in
  ''|*[!0-9]*)
    echo "fm-linear-transport: the request to Linear did not complete" >&2
    exit 4
    ;;
esac

printf '%s\n' "$CODE"
