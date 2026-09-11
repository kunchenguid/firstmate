#!/usr/bin/env bash
# Hold the existing portable lock until the requesting application's pipe closes.
set -eu
ROOT=$1
LOCK=$2
# shellcheck disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"
fm_lock_acquire_wait_bounded "$LOCK" 5 || exit 1
trap 'fm_lock_release "$LOCK"' EXIT
trap 'exit 130' INT TERM
printf 'locked\n'
IFS= read -r _ || true
