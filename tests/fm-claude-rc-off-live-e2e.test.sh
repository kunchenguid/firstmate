#!/usr/bin/env bash
# Opt-in real Claude/Herdr observation for the best-effort RC-off default.
# Run from an already trusted worktree with the target CLAUDE_CONFIG_DIR.
# This creates only a named lab session and verifies the default-session tripwire on exit.
# It deliberately tries to override the managed default and spends one tool-free model turn.
# Other harnesses are not applicable because disableRemoteControl is a Claude setting.
set -euo pipefail
if [ "${FM_CLAUDE_RC_OFF_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_CLAUDE_RC_OFF_LIVE_E2E=1 to observe the real Claude/Herdr RC default'
  exit 0
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for tool in herdr jq; do
  command -v "$tool" >/dev/null || { echo "not ok - required installed harness/tool absent: $tool" >&2; exit 1; }
done
CLAUDE_EXECUTABLE=$(command -v claude 2>/dev/null) || { echo 'not ok - required installed harness/tool absent: claude' >&2; exit 1; }
case "$CLAUDE_EXECUTABLE" in
  /*) ;;
  *) CLAUDE_EXECUTABLE=$(cd "$(dirname "$CLAUDE_EXECUTABLE")" && pwd -P)/$(basename "$CLAUDE_EXECUTABLE") ;;
esac
VERSION=$("$CLAUDE_EXECUTABLE" --version)
"$ROOT/bin/fm-claude-rc-off.sh" check-default "$CLAUDE_EXECUTABLE"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name claude-rc-off)
cleanup() {
  local result=$?
  trap - EXIT
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || result=1
  exit "$result"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
run() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
EVIDENCE="$ROOT/.no-mistakes/rc-evidence"
mkdir -p "$EVIDENCE"
fail() { echo "not ok - $VERSION: $* (captures: $EVIDENCE)" >&2; exit 1; }
capture() { run pane read "$1" --source visible --format text; }
wait_for() {
  local pane=$1 needle=$2 file=$3 attempt
  for ((attempt=0; attempt<90; attempt++)); do
    capture "$pane" > "$EVIDENCE/$file"
    if grep -Fq "$needle" "$EVIDENCE/$file"; then return; fi
    if grep -Fq 'Yes, I trust this folder' "$EVIDENCE/$file"; then fail 'pre-register workspace trust before running this guard'; fi
    sleep 1
  done
  fail "timed out waiting for $needle"
}
submit() {
  run pane send-text "$1" "$2"
  sleep 0.3
  run pane send-keys "$1" enter
}
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

PREFIX="env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CONFIG_DIR=$(shell_quote "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
COMMON="--tools '' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --settings '{\"disableAllHooks\":true,\"disableRemoteControl\":false}'"

OFF=$(run workspace create --cwd "$ROOT" --label rc-enforced | jq -er '.result.root_pane.pane_id')
run pane run "$OFF" "$PREFIX $(shell_quote "$CLAUDE_EXECUTABLE") --remote-control $COMMON"
wait_for "$OFF" '❯' enforced-start.txt
"$ROOT/bin/fm-claude-rc-off.sh" check-default "$CLAUDE_EXECUTABLE" | tee "$EVIDENCE/default-preflight.txt"
submit "$OFF" /remote-control
wait_for "$OFF" 'Unknown command: /remote-control' enforced-off.txt
submit "$OFF" 'Reply with exactly RC_OFF_GUARD_OK and do not use any tools.'
wait_for "$OFF" '● RC_OFF_GUARD_OK' completed-turn.txt
submit "$OFF" /rc
wait_for "$OFF" 'Unknown command: /rc' still-off.txt
"$ROOT/bin/fm-claude-rc-off.sh" check-default "$CLAUDE_EXECUTABLE" | tee "$EVIDENCE/still-off-preflight.txt"
run pane process-info --pane "$OFF" > "$EVIDENCE/guard-process.json"
echo "ok - $VERSION: observed the managed default beat CLI and settings overrides for this lab turn"
