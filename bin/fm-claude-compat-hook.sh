#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER=${1:-}
shift || true

resolve_hook_root() {
  local candidate=${CLAUDE_PROJECT_DIR:-} root
  if [ -n "$candidate" ]; then
    root=$(cd "$candidate" 2>/dev/null && pwd -P) || return 1
  else
    root=$(pwd -P 2>/dev/null) || return 1
  fi
  printf '%s\n' "$root"
}

validate_hook_root() {  # <root> <helper>
  local root=$1 helper=$2 settings=$1/.claude/settings.json
  [ -n "$root" ] || return 1
  [ -n "$helper" ] || return 1
  [ -f "$root/AGENTS.md" ] || return 1
  [ -f "$settings" ] || return 1
  [ -f "$root/bin/fm-hook-host-lib.sh" ] || return 1
  [ -x "$root/bin/$helper" ] || return 1
  grep -Fq 'fm-claude-compat-hook.sh' "$settings" || return 1
  grep -Fq "$helper" "$settings" || return 1
}

case "$HELPER" in
  fm-sessionstart-run.sh|fm-arm-pretool-check.sh|fm-cd-pretool-check.sh|fm-subagent-pretool-check.sh|fm-turnend-guard.sh|fm-claude-stop-autoarm.sh) ;;
  *) exit 0 ;;
esac

ROOT=$(resolve_hook_root) || exit 0
validate_hook_root "$ROOT" "$HELPER" || exit 0

# shellcheck source=bin/fm-hook-host-lib.sh
. "$ROOT/bin/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
  exit 0
fi
printf '%s' "$PAYLOAD" | "$ROOT/bin/$HELPER" "$@"
