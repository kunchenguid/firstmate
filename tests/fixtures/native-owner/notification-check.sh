#!/usr/bin/env bash
# Usage: FM_HOME=<home> FM_PROBE_HOME=<evidence-dir> FM_PROBE_JQ_IMAGE=<image> notification-check.sh
# Required environment: FM_HOME, FM_PROBE_HOME, FM_PROBE_JQ_IMAGE.
# Fixed notification operation, created and scoped by the existing controller.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG=$(cygpath -u "${FM_PROBE_HOME:?}")
export FM_HOME
FM_HOME=$(cygpath -u "${FM_HOME:?}")
BUILD=$(cd "$ROOT/.." && pwd)
export PATH="$BUILD/tools:$PATH"
cd "$ROOT"
. bin/fm-session-lock-lib.sh
fm_session_lock_owned_by_self "$FM_HOME/state"
[ -f "$LOG/owner-operation.complete" ]
challenge=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
if [ "${FM_PROBE_STARTUP_QUEUED:-}" = 1 ]; then
  note=${FM_PROBE_STARTUP_NOTE:?}
else
  bin/fm-wake-drain.sh > "$LOG/cycle-initial-drain.log" 2>&1
  bin/fm-inbox.sh note "Controlled notification. Confirm observation of $challenge; no project action is requested." > "$LOG/cycle-enqueue.log"
  note=$(awk '/^queued / {print $2}' "$LOG/cycle-enqueue.log")
fi
set +e
bin/fm-watch-checkpoint.sh --seconds 3 > "$LOG/cycle-checkpoint.log" 2>&1
rc=$?
set -e
case "$rc" in 0|124) ;; *) exit "$rc" ;; esac
bin/fm-wake-drain.sh > "$LOG/cycle-delivery.log" 2>&1
bin/fm-inbox.sh drain > "$LOG/cycle-message.log"
message=$(<"$LOG/cycle-message.log")
if [ "${FM_PROBE_STARTUP_QUEUED:-}" != 1 ]; then grep -q "$challenge" "$LOG/cycle-message.log"; fi
ack=$(grep 'WAKE_ACK_REQUIRED:' "$LOG/cycle-delivery.log" | tail -1)
seq=$(awk '{for(i=1;i<NF;i++)if($i=="--ack-through")print $(i+1)}' <<< "$ack")
generation=$(awk '{for(i=1;i<NF;i++)if($i=="--recovery-generation")print $(i+1)}' <<< "$ack")
case "$seq" in ''|*[!0-9]*) exit 2 ;; esac
case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
jq -n --arg message "$message" --arg challenge "$challenge" --arg note "$note" --arg seq "$seq" --arg generation "$generation" --argjson checkpointExit "$rc" \
 '{message:$message,challenge:$challenge,note:$note,seq:$seq,generation:$generation,checkpointExit:$checkpointExit}' > "$LOG/notification-check.json"
