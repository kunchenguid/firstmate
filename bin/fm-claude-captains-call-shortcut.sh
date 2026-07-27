#!/usr/bin/env bash
# Claude UserPromptSubmit adapter for exact interactive Firstmate Bearings shortcuts.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P) || exit 0

canonical_file() {
  local path=$1 dir
  [ -f "$path" ] || return 1
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

[ "${CLAUDE_CODE_ENTRYPOINT:-}" = cli ] || exit 0
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || exit 0
PROJECT_ROOT=$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P) || exit 0
[ "$PROJECT_ROOT" = "$ROOT" ] || exit 0

BEARINGS_OWNER=$(canonical_file "$ROOT/.agents/skills/bearings/SKILL.md") || exit 0
CLAUDE_BEARINGS=$(canonical_file "$ROOT/.claude/skills/bearings/SKILL.md") || exit 0
[ "$BEARINGS_OWNER" = "$CLAUDE_BEARINGS" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(cat)
printf '%s' "$PAYLOAD" | jq -e '
  .hook_event_name == "UserPromptSubmit" and
  (.prompt | type == "string") and
  ((.images? // []) | length == 0) and
  ((.attachments? // []) | length == 0) and
  ((.file_attachments? // []) | length == 0) and
  ((.fileAttachments? // []) | length == 0) and
  ((.pasted_contents? // []) | length == 0)
' >/dev/null 2>&1 || exit 0
PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt') || exit 0

shopt -s extglob nocasematch
SHORTCUT=${PROMPT##+([[:space:]])}
SHORTCUT=${SHORTCUT%%+([[:space:]])}

case "$SHORTCUT" in
  s)
    CONTEXT='Firstmate interactive Claude CLI shortcut handling applies only when the current submitted turn has no image attachments. Its complete trimmed text is the exact case-insensitive `s` token, so Claude invokes the project-owned `bearings` skill with the exact `captains-call-only` argument. If any image is attached, the mapping does not apply and the original submission stays ordinary. The project-owned `bearings` skill remains the sole classification and report owner.'
    ;;
  status\?)
    CONTEXT='Firstmate interactive Claude CLI shortcut handling applies only when the current submitted turn has no image attachments. Its complete trimmed text is the exact case-insensitive `status?` token, so Claude invokes the project-owned `bearings` skill with no arguments for its full four-section workflow. If any image is attached, the mapping does not apply and the original submission stays ordinary. The project-owned `bearings` skill remains the sole classification and report owner.'
    ;;
  *)
    exit 0
    ;;
esac

jq -cn --arg context "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $context
  }
}'
