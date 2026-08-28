#!/usr/bin/env bash
# Stable project hook transport for Codex.
# Usage: fm-codex-hook.sh sessionstart|arm-pretool|cd-pretool|stop
# Reads the original Codex hook payload on stdin and passes it unchanged to the
# selected Firstmate hook after verifying the hook process started at a tracked
# Firstmate root. Every unavailable or malformed transport prerequisite steps
# aside with exit 0; the selected hook keeps ownership of its own exit contract.
set -u

# A bash.exe started directly by cmd.exe does not receive Git Bash's usual
# login-path prefix. Supply its own core-tool path without changing directory.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) PATH="/usr/bin:/mingw64/bin:$PATH"; export PATH ;;
esac

EVENT=${1:-}
case "$EVENT" in
  sessionstart) TARGET=fm-sessionstart-run.sh; HOOK_GROUP=SessionStart ;;
  arm-pretool) TARGET=fm-arm-pretool-check.sh; HOOK_GROUP=PreToolUse ;;
  cd-pretool) TARGET=fm-cd-pretool-check.sh; HOOK_GROUP=PreToolUse ;;
  stop) TARGET=fm-turnend-guard.sh; HOOK_GROUP=Stop ;;
  *) exit 0 ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
ROOT=$(pwd -P) || exit 0
[ -x "$ROOT/bin/$TARGET" ] || exit 0
[ -f "$ROOT/AGENTS.md" ] || exit 0
[ -f "$ROOT/.codex/hooks.json" ] || exit 0
jq -e --arg group "$HOOK_GROUP" --arg event "$EVENT" '
  .hooks[$group] | any(.[]?.hooks[]?.command?;
    type == "string" and contains("fm-codex-hook") and endswith(" " + $event))
' "$ROOT/.codex/hooks.json" >/dev/null 2>&1 || exit 0
if [ "$EVENT" = sessionstart ]; then
  # Capture the verified native harness while the stable hook process still has
  # its complete Windows parent chain. Nested startup shells can outlive an
  # intermediate parent before they query the process table.
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$ROOT/bin/fm-session-lock-lib.sh"
  FM_SESSION_HARNESS_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
  export FM_SESSION_HARNESS_PID
fi
printf '%s' "$PAYLOAD" | "$ROOT/bin/$TARGET"
