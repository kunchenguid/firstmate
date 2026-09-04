#!/usr/bin/env bash
# Antigravity hook adapter for Firstmate.
#
# Usage:
#   fm-antigravity-hook.sh sessionstart
#   fm-antigravity-hook.sh task-busy <state-dir> <task-id> <generation>
#   fm-antigravity-hook.sh task-stop <state-dir> <task-id> <generation> <turn-ended-file>
#
# Antigravity discovers .agents/hooks.json in every --add-dir root. The task
# launcher points one added directory at a Firstmate-owned overlay so projects'
# own customization remains untouched. Hook stdin is consumed but never trusted
# for task identity: spawn bakes the canonical state directory, safe task id,
# and fresh busy generation into the isolated hook file.
#
# PreInvocation opens semantic busy state before the model starts or resumes.
# Stop settles that state and publishes the ordinary turn-end edge. Sessionstart
# reuses Firstmate's read-only startup nudge and returns Antigravity's documented
# PreInvocation injectSteps.ephemeralMessage shape.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  echo "usage: $0 sessionstart | task-busy <state-dir> <task-id> <generation> | task-stop <state-dir> <task-id> <generation> <turn-ended-file>" >&2
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
  task-busy)
    [ "$#" -eq 4 ] || usage
    cat >/dev/null
    "$SCRIPT_DIR/fm-busy-event.sh" apply "$2" "$3" busy \
      --gen "$4" --source antigravity-hook --event pre-invocation >/dev/null 2>&1 || true
    printf '{}\n'
    ;;
  task-stop)
    [ "$#" -eq 5 ] || usage
    cat >/dev/null
    "$SCRIPT_DIR/fm-busy-event.sh" apply "$2" "$3" idle \
      --gen "$4" --source antigravity-hook --event stop >/dev/null 2>&1 || true
    : > "$5"
    printf '{"decision":"stop"}\n'
    ;;
  *) usage ;;
esac
