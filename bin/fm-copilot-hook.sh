#!/usr/bin/env bash
# Copilot CLI repository-hook adapter for Firstmate.
#
# Usage:
#   fm-copilot-hook.sh session-start
#   fm-copilot-hook.sh pretool-arm
#   fm-copilot-hook.sh pretool-cd
#   fm-copilot-hook.sh pretool-subagent
#   fm-copilot-hook.sh agent-stop
#
# Copilot's native camelCase hooks use JSON decision objects rather than
# Claude/Codex's exit-2 Stop transport. This adapter keeps the shared Firstmate
# scripts authoritative and translates only the hook boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}

case "$MODE" in
  session-start)
    cat >/dev/null 2>&1 || true
    command -v jq >/dev/null 2>&1 || exit 0
    context=$("$SCRIPT_DIR/fm-sessionstart-nudge.sh" 2>/dev/null || true)
    [ -n "$context" ] || exit 0
    jq -cn --arg additionalContext "$context" '{additionalContext:$additionalContext}'
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
    payload=$(cat 2>/dev/null || true)
    [ -n "$payload" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    err=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-stop.XXXXXX") || exit 0
    trap 'rm -f "$err"' EXIT
    printf '%s' "$payload" | "$SCRIPT_DIR/fm-turnend-guard.sh" >/dev/null 2>"$err"
    rc=$?
    [ "$rc" -ne 0 ] || exit 0
    [ "$rc" -eq 2 ] || exit 0
    reason=$(cat "$err" 2>/dev/null || true)
    [ -n "$reason" ] || reason='Firstmate supervision must be restored before this turn ends.'
    jq -cn --arg reason "$reason" '{decision:"block",reason:$reason}'
    ;;
  *)
    echo "usage: $(basename "$0") {session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop}" >&2
    exit 2
    ;;
esac
