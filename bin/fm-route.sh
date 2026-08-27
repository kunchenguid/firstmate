#!/usr/bin/env bash
# fm-route.sh - validate and select a subscription routing profile.
# Usage: fm-route.sh select --request REQUEST.json --candidates CANDIDATES.json [--now EPOCH]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-routing-lib.sh
. "$SCRIPT_DIR/fm-routing-lib.sh"

usage() {
  fm_route_diagnostic 'usage: fm-route.sh select --request REQUEST.json --candidates CANDIDATES.json [--now EPOCH]'
  exit 2
}

[ "${1:-}" = select ] || usage
shift

REQUEST=
CANDIDATES=
NOW=$(date +%s)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request)
      [ -z "$REQUEST" ] && [ "$#" -ge 2 ] || usage
      REQUEST=$2
      shift 2
      ;;
    --candidates)
      [ -z "$CANDIDATES" ] && [ "$#" -ge 2 ] || usage
      CANDIDATES=$2
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || usage
      NOW=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$REQUEST" ] && [ -f "$REQUEST" ] && [ -r "$REQUEST" ] || {
  fm_route_diagnostic 'request file is required and must be readable'
  exit 1
}
[ -n "$CANDIDATES" ] && [ -f "$CANDIDATES" ] && [ -r "$CANDIDATES" ] || {
  fm_route_diagnostic 'candidates file is required and must be readable'
  exit 1
}
case "$NOW" in
  ''|*[!0-9]*)
    fm_route_diagnostic 'invalid --now: expected non-negative epoch'
    exit 1
    ;;
esac

fm_route_validate_request "$REQUEST"
fm_route_validate_candidates "$CANDIDATES"
fm_route_select "$REQUEST" "$CANDIDATES"
