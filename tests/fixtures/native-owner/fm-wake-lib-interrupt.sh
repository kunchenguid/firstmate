#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh.actual"

_fm_atomic_replace() {
  case "$1:$2" in
    *.wake-queue.ack.*:"$FM_WAKE_QUEUE")
      case "$(cat "$STATE/.watcher-down" 2>/dev/null || true)" in
        acked:*)
          printf 'ready\n' > "$(cygpath -u "${FM_PROBE_HOME:?}")/ack-boundary-ready"
          sleep 30
          ;;
      esac
      ;;
  esac
  command mv -f -- "$1" "$2"
}
