#!/usr/bin/env bash
# AGY session-open adapter: the RUN tier transport for Antigravity CLI.
#
# Registered in tracked .agents/hooks.json for AGY's `SessionStart` step.
# It is a thin transport around bin/fm-sessionstart-run.sh, which remains the
# single owner of source routing, eligibility, and the digest itself.
#
# AGY injects a hook's `injectSteps` array containing an `ephemeralMessage`
# directly into model context, so the digest lands before the first turn and
# the helm is taken without model discretion.
#
# Usage: fm-sessionstart-agy.sh [--source <source>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SOURCE" ] && [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
    SOURCE=$(printf '%s' "$PAYLOAD" | jq -r '.source // empty' 2>/dev/null || true)
  fi
fi
[ -n "$SOURCE" ] || SOURCE=startup

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "$SOURCE" </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -n --arg c "$DIGEST" '{"injectSteps": [{"ephemeralMessage": $c}]}' 2>/dev/null || true
exit 0
