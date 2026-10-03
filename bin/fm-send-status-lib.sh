#!/usr/bin/env bash
# fm-send-status-lib.sh - the one caller-side reading of bin/fm-send.sh's exit.
# No dependencies, no side effects on source. set -u / set -e safe.

# fm_send_delivered <fm-send-exit> [<fm-send-output>]
# Succeeds when fm-send durably delivered the steer: exit 0, or exit 4 - the
# composer-held doorbell-skip, whose record IS durable (bin/fm-send.sh header).
# On 4 the skip is surfaced as a warning on stderr; a caller treats the send as
# landed and never resends it or keeps retry state for it.
fm_send_delivered() {
  local line
  case "$1" in
  0) return 0 ;;
  4)
    line=$(printf '%s\n' "${2:-}" | grep -m1 '^fm-send: doorbell-skip' || true)
    printf 'warning: %s\n' "${line:-fm-send: doorbell-skip (the steer is durably recorded but its doorbell was skipped because the target composer holds pending text; do not resend)}" >&2
    return 0
    ;;
  esac
  return 1
}
