#!/usr/bin/env bash
# GitHub Copilot CLI hook transport for primary and worker sessions.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${COPILOT_CLI:-}" = 1 ] || exit 0

case "${1:-}" in
  session-start)
    PAYLOAD=$(cat 2>/dev/null || true)
    DIGEST=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh" 2>/dev/null || true)
    [ -n "$DIGEST" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    jq -n --arg c "$DIGEST" '{additionalContext:$c}' 2>/dev/null || true
    ;;
  primary-stop)
    exec "$SCRIPT_DIR/fm-turnend-guard-cursor.sh" --copilot
    ;;
  pretool)
    case "${2:-}" in
      arm) exec "$SCRIPT_DIR/fm-arm-pretool-check.sh" --copilot ;;
      cd) exec "$SCRIPT_DIR/fm-cd-pretool-check.sh" --copilot ;;
      subagent) exec "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --copilot ;;
      *) exit 0 ;;
    esac
    ;;
  worker-event)
    [ "$#" -eq 7 ] || exit 0
    STATE=$2
    ID=$3
    GEN=$4
    VERDICT=$5
    EVENT=$6
    TURNEND=$7
    case "$VERDICT" in busy|idle) ;; *) exit 0 ;; esac
    case "$ID:$GEN:$EVENT" in
      *[!A-Za-z0-9._:-]*) exit 0 ;;
    esac
    if "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" "$VERDICT" \
      --gen "$GEN" --source copilot-hook --event "$EVENT" >/dev/null 2>&1; then
      if [ "$TURNEND" != "-" ]; then
        touch "$TURNEND" 2>/dev/null || true
      fi
      if [ "$EVENT" = user-prompt-submitted ]; then
        ACK="$STATE/$ID.copilot-prompt-submitted"
        ACK_TMP="$ACK.tmp.$$"
        if printf '%s:%s:%s\n' "$GEN" "$$" "${RANDOM:-0}" > "$ACK_TMP" 2>/dev/null; then
          mv -f "$ACK_TMP" "$ACK" 2>/dev/null || rm -f "$ACK_TMP"
        fi
      fi
    fi
    ;;
  *)
    exit 0
    ;;
esac
exit 0
