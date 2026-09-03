#!/usr/bin/env bash
# Copilot CLI repository-hook adapter for Firstmate primary sessions.
# Usage: fm-copilot-hook.sh session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop
#
# The shared scripts remain authoritative.
# This file translates only Copilot's native hook output objects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}

[ "${COPILOT_CLI:-}" = "1" ] || exit 0

case "$MODE" in
  session-start)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    OUT=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-session-start.XXXXXX") || exit 0
    trap 'rm -f "$OUT"' EXIT HUP INT TERM
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh" > "$OUT" 2>/dev/null || true
    [ -s "$OUT" ] || exit 0
    jq -Rs '{additionalContext:.}' < "$OUT"
    ;;
  pretool-arm)
    exec "$SCRIPT_DIR/fm-arm-pretool-check.sh" --claude
    ;;
  pretool-cd)
    exec "$SCRIPT_DIR/fm-cd-pretool-check.sh" --claude
    ;;
  pretool-subagent)
    exec "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --claude
    ;;
  agent-stop)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    REASON_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-agent-stop.XXXXXX") || exit 0
    trap 'rm -f "$REASON_FILE"' EXIT HUP INT TERM
    if printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" >/dev/null 2>"$REASON_FILE"; then
      exit 0
    else
      STATUS=$?
    fi
    [ "$STATUS" -eq 2 ] || exit 0
    REASON=$(cat "$REASON_FILE" 2>/dev/null || true)
    [ -n "$REASON" ] || REASON='Restore Firstmate supervision before ending this turn.'
    jq -cn --arg reason "$REASON" '{decision:"block",reason:$reason}'
    ;;
  *)
    echo "usage: $(basename "$0") session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop" >&2
    exit 2
    ;;
esac
