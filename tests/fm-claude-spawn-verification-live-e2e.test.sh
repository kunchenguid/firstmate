#!/usr/bin/env bash
# Opt-in live guard for the rendered Claude signals used by fm-spawn's
# deterministic post-launch verification.
#
# Run after a Claude upgrade and before trusting refreshed evidence:
#   FM_CLAUDE_SPAWN_VERIFY_LIVE=1 bin/fm-test-run.sh tests/fm-claude-spawn-verification-live-e2e.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

[ "${FM_CLAUDE_SPAWN_VERIFY_LIVE:-0}" = 1 ] || {
  echo "skip: set FM_CLAUDE_SPAWN_VERIFY_LIVE=1 to run the credentialed Claude launch-verification guard"
  exit 0
}
command -v tmux >/dev/null 2>&1 || fail "tmux is not installed"
command -v claude >/dev/null 2>&1 || fail "claude is not installed"

TMP_ROOT=$(fm_test_tmproot fm-claude-spawn-verification-live)
mkdir -p "$TMP_ROOT"
PROJECT="$TMP_ROOT/project"
fm_git_init_commit "$PROJECT"
SESSION="fm-claude-verify-$$-$RANDOM"
TARGET=
CLAUDE_VERSION=$(claude --version 2>&1 | head -1)

live_cleanup() {
  if [ -n "$TARGET" ]; then
    tmux send-keys -t "$TARGET" Escape >/dev/null 2>&1 || true
    tmux send-keys -t "$TARGET" -l /exit >/dev/null 2>&1 || true
    tmux send-keys -t "$TARGET" Enter >/dev/null 2>&1 || true
    sleep 0.5
  fi
  tmux kill-session -t "=$SESSION" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap live_cleanup EXIT INT TERM

TARGET=$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION" -c "$PROJECT")
CONFIG_PREFIX=
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  printf -v CONFIG_PREFIX 'CLAUDE_CONFIG_DIR=%q ' "$CLAUDE_CONFIG_DIR"
fi
printf -v COMMAND \
  '%sCLAUDE_CODE_CHILD_SESSION=1 env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions %q' \
  "$CONFIG_PREFIX" \
  'Use the Bash tool to run pwd once, then reply with exactly READY.'
tmux send-keys -t "$TARGET" -l "$COMMAND"
tmux send-keys -t "$TARGET" Enter

prior_tokens=
prior_tools=
snapshot=
verified=
i=0
while [ "$i" -lt 240 ]; do
  snapshot=$(tmux capture-pane -p -S -160 -t "$TARGET" 2>/dev/null || true)
  if [ -n "$snapshot" ]; then
    if failure=$(fm_control_claude_startup_failure "$snapshot"); then
      fail "Claude $CLAUDE_VERSION rendered $failure"$'\n'"$snapshot"
    fi
    if fm_control_claude_startup_dialog "$snapshot" >/dev/null; then
      tmux send-keys -t "$TARGET" Enter
    elif fm_control_claude_busy_visible "$snapshot"; then
      verified=busy-affordance
      break
    else
      tools=$(fm_control_claude_tool_activity "$snapshot")
      if [ -n "$tools" ] && [ "$tools" != "$prior_tools" ]; then
        verified='tool-row'
        break
      fi
      tokens=$(fm_control_claude_token_counter "$snapshot")
      if [ -n "$tokens" ] && [ -n "$prior_tokens" ] \
         && [ "$tokens" != "$prior_tokens" ]; then
        verified=token-counter
        break
      fi
      [ -z "$tools" ] || prior_tools=$tools
      [ -z "$tokens" ] || prior_tokens=$tokens
    fi
  fi
  i=$((i + 1))
  sleep 0.25
done

[ -n "$verified" ] \
  || fail "Claude $CLAUDE_VERSION exposed no supported activity proof within 60 seconds"$'\n'"${snapshot:-<empty pane capture>}"
pass "Claude $CLAUDE_VERSION launch verification observes real activity through $verified with child-session mode cleared"
