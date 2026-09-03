#!/usr/bin/env bash
# Opt-in live guard for Copilot CLI's primary hook contract.
set -u

if [ "${FM_COPILOT_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_COPILOT_LIVE_E2E=1 to run the credentialed Copilot CLI hook guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v copilot >/dev/null 2>&1 || fail "copilot is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is required"

if [ -n "${FM_COPILOT_LIVE_TMP_ROOT:-}" ]; then
  TMP_ROOT=$FM_COPILOT_LIVE_TMP_ROOT
  [ ! -e "$TMP_ROOT" ] || fail "FM_COPILOT_LIVE_TMP_ROOT already exists: $TMP_ROOT"
  mkdir -p "$TMP_ROOT"
  FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
else
  TMP_ROOT=$(fm_test_tmproot fm-copilot-primary-live-e2e)
fi
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.github/hooks" "$REPO/hooks"
git -C "$REPO" init -q

cat > "$REPO/.github/hooks/live.json" <<'JSON'
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      {
        "type": "command",
        "bash": "./hooks/session-start.sh",
        "cwd": ".",
        "timeoutSec": 10
      }
    ],
    "preToolUse": [
      {
        "type": "command",
        "matcher": "bash",
        "bash": "./hooks/pretool.sh",
        "cwd": ".",
        "timeoutSec": 10
      }
    ],
    "agentStop": [
      {
        "type": "command",
        "bash": "./hooks/agent-stop.sh",
        "cwd": ".",
        "timeoutSec": 10
      }
    ],
    "notification": [
      {
        "type": "command",
        "matcher": "shell_completed",
        "bash": "./hooks/notification.sh",
        "cwd": ".",
        "timeoutSec": 10
      }
    ]
  }
}
JSON

cat > "$REPO/hooks/session-start.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat > .session-start-payload.json
jq -cn '{additionalContext:"Include LIVE_SESSION_START_OK in every response."}'
SH

cat > "$REPO/hooks/pretool.sh" <<'SH'
#!/usr/bin/env bash
set -u
payload=$(cat)
printf '%s' "$payload" > .pretool-payload.json
command=$(printf '%s' "$payload" | jq -r '.toolArgs.command // empty')
case "$command" in
  *LIVE_PRETOOL_EXECUTED*)
    jq -cn '{permissionDecision:"deny",permissionDecisionReason:"LIVE_PRETOOL_DENIED"}'
    ;;
esac
SH

cat > "$REPO/hooks/agent-stop.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat > .agent-stop-payload.json
count=0
[ ! -f .agent-stop-count ] || count=$(cat .agent-stop-count)
count=$((count + 1))
printf '%s' "$count" > .agent-stop-count
if [ "$count" -eq 1 ]; then
  jq -cn '{decision:"block",reason:"Reply exactly: LIVE_SESSION_START_OK LIVE_AGENT_STOP_OK"}'
else
  jq -cn '{decision:"allow"}'
fi
SH
chmod +x "$REPO/hooks/"*.sh

cat > "$REPO/hooks/notification.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat > .notification-payload.json
jq -cn '{additionalContext:"Reply exactly: LIVE_BACKGROUND_NOTIFICATION_OK"}'
SH
chmod +x "$REPO/hooks/notification.sh"

git -C "$REPO" add .
git -C "$REPO" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid \
  commit -qm initial

PROMPT='Use the bash tool to run: printf LIVE_PRETOOL_EXECUTED > should-not-exist. Then reply exactly: INITIAL_RESPONSE'
OUT=$(cd "$REPO" && copilot -p "$PROMPT" --allow-all --no-ask-user \
  --no-auto-update --no-remote --no-remote-export --add-dir "$REPO" --silent)
STATUS=$?
expect_code 0 "$STATUS" "Copilot live hook run should succeed"

assert_contains "$OUT" "LIVE_SESSION_START_OK LIVE_AGENT_STOP_OK" \
  "agentStop did not force the expected continuation with sessionStart context"
assert_absent "$REPO/should-not-exist" "preToolUse did not deny the protected bash command"
[ "$(cat "$REPO/.agent-stop-count" 2>/dev/null)" = 2 ] \
  || fail "agentStop did not run once to block and once to allow"
jq -e '(.source == "startup" or .source == "new") and (.sessionId | type) == "string"' \
  "$REPO/.session-start-payload.json" >/dev/null \
  || fail "sessionStart payload did not use the documented camelCase shape"
jq -e '.toolName == "bash" and (.toolArgs.command | contains("LIVE_PRETOOL_EXECUTED"))' \
  "$REPO/.pretool-payload.json" >/dev/null \
  || fail "preToolUse payload did not expose the documented toolName/toolArgs shape"
jq -e '.stopReason == "end_turn" and .stop_hook_active == true' \
  "$REPO/.agent-stop-payload.json" >/dev/null \
  || fail "the final agentStop payload did not report the bounded continuation"

BACKGROUND_PROMPT='Run this exact bash command as an attached background task: sleep 1; printf LIVE_BACKGROUND_DONE > background-result. Wait for its completion notification.'
BACKGROUND_OUT=$(cd "$REPO" && copilot -p "$BACKGROUND_PROMPT" --allow-all --no-ask-user \
  --no-auto-update --no-remote --no-remote-export --add-dir "$REPO" --silent)
STATUS=$?
expect_code 0 "$STATUS" "Copilot background notification run should succeed"
assert_contains "$BACKGROUND_OUT" "LIVE_BACKGROUND_NOTIFICATION_OK" \
  "a completed attached shell task did not resume the model through its notification"
[ "$(cat "$REPO/background-result" 2>/dev/null)" = LIVE_BACKGROUND_DONE ] \
  || fail "the attached background shell task did not complete"
jq -e '.notification_type == "shell_completed"' "$REPO/.notification-payload.json" >/dev/null \
  || fail "the background completion did not emit Copilot's shell_completed notification"

version=$(copilot --version 2>/dev/null | head -1 | tr -d '\r')
pass "Copilot live hooks: startup context, tool denial, bounded stop continuation, and background completion wake ($version)"
