#!/usr/bin/env bash
# Append one producer status event under the shared status-publication lock.
# Usage: fm-status-append.sh <absolute-status-file> <one-line-event>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: fm-status-append.sh <absolute-status-file> <one-line-event>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
STATUS_FILE=$1
EVENT=$2

case "$STATUS_FILE" in
  /*.status) ;;
  *)
    echo "error: status file must be an absolute .status path" >&2
    exit 1
    ;;
esac
case "$EVENT" in
  ''|*$'\n'*|*$'\r'*)
    echo "error: status event must be one non-empty line" >&2
    exit 1
    ;;
esac
[ -d "${STATUS_FILE%/*}" ] || {
  echo "error: status directory does not exist: ${STATUS_FILE%/*}" >&2
  exit 1
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_status_append "$STATUS_FILE" "$EVENT"
