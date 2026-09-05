#!/usr/bin/env bash
# Antigravity hook adapter for Firstmate.
#
# Usage:
#   fm-antigravity-hook.sh sessionstart
#
# The added Firstmate home supplies .agents/hooks.json. Sessionstart reuses
# Firstmate's read-only startup nudge and returns Antigravity's documented
# PreInvocation injectSteps.ephemeralMessage shape.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  echo "usage: $0 sessionstart" >&2
  exit 2
}

mode=${1:-}
case "$mode" in
  sessionstart)
    [ "$#" -eq 1 ] || usage
    cat >/dev/null
    message=$(
      FM_SESSIONSTART_HOOK_MODE=1 \
        "$SCRIPT_DIR/fm-sessionstart-nudge.sh" 2>/dev/null || true
    )
    if [ -n "$message" ]; then
      jq -n --arg message "$message" \
        '{injectSteps:[{ephemeralMessage:$message}]}'
    else
      printf '{}\n'
    fi
    ;;
  *) usage ;;
esac
