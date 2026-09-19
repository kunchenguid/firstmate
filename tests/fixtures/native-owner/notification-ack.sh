#!/usr/bin/env bash
# Usage: FM_HOME=<home> FM_PROBE_HOME=<evidence-dir> FM_PROBE_JQ_IMAGE=<image> notification-ack.sh
# Required environment: FM_HOME, FM_PROBE_HOME, FM_PROBE_JQ_IMAGE.
# Only controller-validated receipt data is accepted; no command text is parsed.
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
request="$LOG/notification-ack-request.json"
note=$(jq -r .note "$request")
seq=$(jq -r .seq "$request")
generation=$(jq -r .generation "$request")
evidence=$(jq -er '.ownerEvidence | select(type == "string" and length > 0)' "$request")
case "$note" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
case "$seq" in ''|*[!0-9]*) exit 2 ;; esac
case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
case "${FM_PROBE_ACK_FAULT:-}" in
  zero-missing)
    rm -f "$LOG/notification-ack.json"
    exit 0
    ;;
  zero-malformed)
    printf '{broken\n' > "$LOG/notification-ack.json"
    exit 0
    ;;
  zero-mismatched)
    jq -n --arg ownerEvidence mismatch '{acknowledged:true,ownerEvidence:$ownerEvidence}' > "$LOG/notification-ack.json"
    exit 0
    ;;
  zero-unproven)
    jq -n --arg ownerEvidence "$evidence" '{acknowledged:true,ownerEvidence:$ownerEvidence}' > "$LOG/notification-ack.json"
    exit 0
    ;;
esac
bin/fm-inbox.sh drain --ack "$note" > "$LOG/cycle-inbox-ack.log"
if [ "${FM_PROBE_ACK_FAULT:-}" = partial ]; then
  printf 'partial\n' > "$LOG/ack-fault-ready"
  sleep 30
  exit 125
fi
bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$generation" > "$LOG/cycle-ack.log" 2>&1
[ ! -s "$FM_HOME/state/.wake-queue" ]
[ -f "$FM_HOME/state/inbox/handled/$note.note" ]
if [ "${FM_PROBE_ACK_FAULT:-}" = complete ]; then
  printf 'complete\n' > "$LOG/ack-fault-ready"
  sleep 30
  exit 125
fi
jq -n --arg ownerEvidence "$evidence" '{acknowledged:true,queueEmpty:true,ownerEvidence:$ownerEvidence}' > "$LOG/notification-ack.json"
