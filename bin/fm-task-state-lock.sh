#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state directory is required}
ATTEMPTS=${2:-50}
[ -d "$STATE" ] || exit 1
case "$ATTEMPTS" in
  ''|*[!0-9]*) exit 1 ;;
esac
[ "$ATTEMPTS" -ge 1 ] && [ "$ATTEMPTS" -le 50 ] || exit 1
FM_STATE_OVERRIDE=$STATE
export FM_STATE_OVERRIDE
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK="$STATE/.task-state.lock"
attempt=0
while ! fm_lock_try_acquire "$LOCK"; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    printf 'timeout\n'
    exit 2
  fi
  sleep 0.1
done
cleanup() { fm_lock_release "$LOCK"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
printf 'locked\n'
IFS= read -r _ || true
