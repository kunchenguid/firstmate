#!/usr/bin/env bash
# Usage: FM_HOME=<home> FM_PROBE_HOME=<runtime> ack.sh
# Required environment: FM_HOME and FM_PROBE_HOME.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LOG=$(cygpath -u "${FM_PROBE_HOME:?}")
export FM_HOME
FM_HOME=$(cygpath -u "${FM_HOME:?}")
export PATH="$ROOT/bin/native-owner/tools:$PATH"
cd "$ROOT"
. bin/fm-session-lock-lib.sh
fm_session_lock_owned_by_self "$FM_HOME/state"
request="$LOG/notification-ack-request.json"
evidence=$(jq -er '.ownerEvidence | select(type == "string" and length > 0)' "$request")
printf '%s' "$evidence" | bash bin/native-owner/ack-evidence.sh acknowledge-token
jq -n --arg ownerEvidence "$evidence" '{acknowledged:true,ownerEvidence:$ownerEvidence}' > "$LOG/notification-ack.json"
