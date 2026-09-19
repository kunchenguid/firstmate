#!/usr/bin/env bash
# Cursor session-open adapter: the RUN tier transport for Cursor Agent CLI.
#
# Registered in tracked .cursor/hooks.json for Cursor's `sessionStart` step.
# It is a thin transport around bin/fm-sessionstart-run.sh, which remains the
# single owner of source routing, eligibility, and the digest itself.
#
# Cursor injects a hook's `additional_context` string straight into model
# context, so the digest lands before the first turn and the helm is taken
# without model discretion. Verified live on 2026.08.11-e8db854.
#
# Usage: fm-sessionstart-cursor.sh --source <source>
# Cursor's payload has no Claude-style `source` field, so the registration
# supplies it.
#
# Every path exits 0 and prints either nothing or one JSON object. Cursor blocks
# session initialization when a sessionStart hook exits 2 (index.js @ 4823085
# maps it to `{continue:false}`), so a failed session start must reach the agent
# as digest text it can act on, never as a refusal to open the session.
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

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "$SOURCE" </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -n --arg c "$DIGEST" '{additional_context:$c}' 2>/dev/null || true
exit 0
