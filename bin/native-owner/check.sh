#!/usr/bin/env bash
# Usage: FM_HOME=<home> FM_PROBE_HOME=<runtime> FM_PROBE_JQ_IMAGE=<image> check.sh
# Required environment: FM_HOME, FM_PROBE_HOME, and FM_PROBE_JQ_IMAGE.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LOG=$(cygpath -u "${FM_PROBE_HOME:?}")
export FM_HOME
FM_HOME=$(cygpath -u "${FM_HOME:?}")
export PATH="$ROOT/bin/native-owner/tools:$PATH"
cd "$ROOT"
. bin/fm-session-lock-lib.sh
fm_session_lock_owned_by_self "$FM_HOME/state"
set +e
bin/fm-watch-checkpoint.sh --seconds 1 > "$LOG/checkpoint.log" 2>&1
rc=$?
set -e
case "$rc" in 0|124) ;; *) exit "$rc" ;; esac
bin/fm-wake-drain.sh > "$LOG/delivery.log" 2>&1
if ! grep -q 'WAKE_ACK_REQUIRED:' "$LOG/delivery.log"; then
  if grep -Eq 'OPEN DECISIONS|UNREAD STATUS|RECORD DIVERGENCE|STATUS OUTCOME BACKSTOP' "$LOG/checkpoint.log" "$LOG/delivery.log"; then
    printf 'Unqueued work requires reconciliation; captured in %s\n' "$LOG" >&2
    exit 2
  fi
  printf '{"quiet":true}\n' > "$LOG/notification-check.json"
  exit 0
fi
bin/fm-inbox.sh drain > "$LOG/inbox.log"
target=$(bash bin/native-owner/ack-evidence.sh capture-json)
challenge=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
message="$(<"$LOG/checkpoint.log")
$(<"$LOG/delivery.log")
$(<"$LOG/inbox.log")"
jq -n --arg message "$message" --arg challenge "$challenge" --argjson target "$target" \
  '$target + {message:$message,challenge:$challenge}' > "$LOG/notification-check.json"
