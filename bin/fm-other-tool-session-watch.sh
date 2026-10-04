#!/usr/bin/env bash
# Detects a new codex/opencode/agy/cursor-agent/grok/kimi process on this
# machine (not just agmsg-registered ones) and re-arms itself via
# fm-procevent-when.sh so detection keeps running after each fire.
set -euo pipefail

STATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state/.other-tool-session-seen"
touch "$STATE"

PATTERN='(^|/)(codex|opencode|agy|cursor-agent|grok|kimi)($| )'

# ps|grep is intentional here, not pgrep
# shellcheck disable=SC2009
current_sessions() {
  ps -axo pid=,lstart=,comm=,args= 2>/dev/null \
    | grep -E "$PATTERN" \
    | grep -v fm-other-tool-session-watch.sh \
    | awk '{printf "%s|%s|%s\n", $1, $2" "$3" "$4" "$5, $0}'
}

new_sessions() {
  local seen_keys current line key
  seen_keys=$(cut -d'|' -f1-2 "$STATE" 2>/dev/null || true)
  current=$(current_sessions)
  [ -z "$current" ] && return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key=$(printf '%s\n' "$line" | cut -d'|' -f1-2)
    if ! printf '%s\n' "$seen_keys" | grep -qxF "$key"; then
      printf '%s\n' "$line"
    fi
  done <<< "$current"
}

case "${1:-}" in
  check)
    [ -n "$(new_sessions)" ]
    ;;
  fire)
    new=$(new_sessions)
    if [ -n "$new" ]; then
      echo "새 세션 감지:"
      printf '%s\n' "$new" | cut -d'|' -f3-
    fi
    current_sessions | cut -d'|' -f1-2 >> "$STATE"
    sort -u -o "$STATE" "$STATE"
    bin/fm-procevent-when.sh retire other-tool-session >/dev/null 2>&1 || true
    exec bin/fm-procevent-when.sh arm other-tool-session \
      --interval 60 --stable 1 \
      --condition "$0" check \
      --action "$0" fire
    ;;
  *)
    echo "usage: $0 check|fire" >&2
    exit 2
    ;;
esac
