#!/usr/bin/env bash
# Classify observed harness/proxy failure text into quota/auth/other.
# Usage:
#   fm-capacity-classify.sh [--file <path>]
#
# Output is key=value lines:
#   class=quota|auth|other
#   reason=<stable signature name>
#   reset_at=<raw reset text>          # when observable
#   reset_epoch=<epoch seconds>        # when parseable
#   cooldown_ttl_secs=<seconds>        # when reset_epoch is in the future
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

FILE=

usage() {
  sed -n '2,12p' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      [ "$#" -gt 1 ] || { echo "error: --file requires a path" >&2; exit 2; }
      FILE=$2
      shift 2
      ;;
    --file=*)
      FILE=${1#--file=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -n "$FILE" ]; then
  TEXT=$(cat "$FILE")
else
  TEXT=$(cat)
fi

fm_capacity_classify_text "$TEXT"
