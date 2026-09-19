#!/usr/bin/env bash
# Usage: zero-recovery.sh present|acknowledge|append|load-cleanup-failure <home> [generation-or-token]
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
export FM_HOME
FM_HOME=$(cygpath -u "${2:?}")
export FM_STATE_OVERRIDE="$FM_HOME/state"
mkdir -p "$FM_HOME/state"
cd "$ROOT"
case "${1:-}" in
  present)
    : > "$FM_HOME/state/.wake-queue"
    . bin/fm-wake-lib.sh
    fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" downtime
    error=$(mktemp "$FM_HOME/state/.zero-recovery.XXXXXX")
    trap 'rm -f -- "$error"' EXIT
    bin/fm-wake-drain.sh > /dev/null 2> "$error"
    ack=$(grep '^WAKE_ACK_REQUIRED:' "$error" | tail -1)
    seq=$(awk '{for(i=1;i<NF;i++)if($i=="--ack-through")print $(i+1)}' <<< "$ack")
    generation=$(awk '{for(i=1;i<NF;i++)if($i=="--recovery-generation")print $(i+1)}' <<< "$ack")
    [ "$seq" = 0 ]
    case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    printf '%s\t%s\n' "$seq" "$generation"
    ;;
  acknowledge)
    generation=${3:-}
    case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    bin/fm-wake-drain.sh --ack-through 0 --recovery-generation "$generation"
    ;;
  append)
    . bin/fm-wake-lib.sh
    fm_wake_append check later-notification 'later notification remains pending'
    ;;
  load-cleanup-failure)
    token=${3:?}
    load_rc=0
    . bin/fm-wake-lib.sh
    rm() {
      case "$*" in
        *fm-wake-ack-derived.*fm-wake-ack-expected.*) return 1 ;;
        *) command rm "$@" ;;
      esac
    }
    fm_wake_ack_evidence_load "$token" || load_rc=$?
    [ "$load_rc" = 0 ]
    [ "$FM_WAKE_ACK_EVIDENCE_CUTOFF" = 1 ]
    fm_wake_ack_evidence_clear
    ;;
  *) exit 2 ;;
esac
