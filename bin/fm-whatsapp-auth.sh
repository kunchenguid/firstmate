#!/usr/bin/env bash
# Read-only WhatsApp main-session authentication and availability.
# Usage: fm-whatsapp-auth.sh <absolute-home> owned|probe
# owned: require descent from the home's live lock-owning harness, print PID.
# probe: print checkpoint or unavailable; no watcher/terminal claim is made.
# This stage has no verified unattended wake adapter. A live main can consume
# its inbox at a checkpoint; neither a live PID nor a note starts a missing main.
# Session identity remains owned by fm-session-lock-lib.sh, shared by all backends.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SELF_DIR/fm-session-lock-lib.sh"
case "${1:-}" in /*) ;; *) echo 'absolute home required' >&2; exit 2 ;; esac
state="$1/state"
holder=$(cat "$state/.lock" 2>/dev/null || true)
case "$holder" in ''|*[!0-9]*) holder='' ;; esac
case "${2:-}" in
  owned)
    [ -n "$holder" ] && [ ! -L "$state/.lock" ] \
      && fm_harness_pid_alive "$holder" && fm_session_lock_owned_by_self "$state" \
      || { echo 'WhatsApp response requires the owning main session' >&2; exit 1; }
    printf '%s\n' "$holder"
    ;;
  probe)
    if [ -n "$holder" ] && [ ! -L "$state/.lock" ] && fm_harness_pid_alive "$holder"; then
      echo checkpoint
    else
      echo unavailable
    fi
    ;;
  *) echo 'usage: fm-whatsapp-auth.sh <absolute-home> owned|probe' >&2; exit 2 ;;
esac
