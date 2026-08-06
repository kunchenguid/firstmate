#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state directory is required}
[ -d "$STATE" ] || exit 1
FM_STATE_OVERRIDE=$STATE
export FM_STATE_OVERRIDE
. "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK="$STATE/.task-state.lock"
fm_lock_acquire_wait "$LOCK"
cleanup() { fm_lock_release "$LOCK"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
printf 'locked\n'
IFS= read -r _ || true
