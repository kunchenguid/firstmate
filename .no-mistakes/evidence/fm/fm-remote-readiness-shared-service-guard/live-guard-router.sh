#!/usr/bin/env bash
set -eu
printf 'herdr %s\n' "$*" >> "$LIVE_CALLS"
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "$#" -ge 2 ] && [ "$2" = "$LIVE_SESSION" ] || exit 64
    shift 2
  else
    args+=("$1"); shift
  fi
done
export HOME="$LIVE_ACCOUNT_HOME"
exec "$LIVE_ROOT/bin/fm-herdr-lab.sh" run "$LIVE_SESSION" "${args[@]}"
