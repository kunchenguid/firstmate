#!/usr/bin/env bash
# Transparent session router: execute only the real Herdr through the lab helper.
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in --session) shift 2 ;; --session=*) shift ;; *) args+=("$1"); shift ;; esac
done
exec env HOME="$LIVE_ORIGINAL_HOME" PATH="$LIVE_ORIGINAL_PATH" FM_HERDR_LAB_STATE_DIR="$LIVE_ROOT/.test-lab-state" "$LIVE_ROOT/bin/fm-herdr-lab.sh" run "$LIVE_HERDR_SESSION" "${args[@]}"
