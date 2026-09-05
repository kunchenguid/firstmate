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
mkdir -p "$REPO/.github/hooks" "$REPO/hooks" "$REPO/bin" "$REPO/state"
git -C "$REPO" init -q
: > "$REPO/AGENTS.md"

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
        "bash": "./hooks/pretool-arm.sh",
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

cp "$ROOT/bin/fm-copilot-hook.sh" "$ROOT/bin/fm-hook-host-lib.sh" \
   "$ROOT/bin/fm-harness-process-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" \
   "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-operational-input.sh" \
   "$ROOT/bin/fm-arm-pretool-check.sh" "$ROOT/bin/fm-arm-command-policy.mjs" \
   "$REPO/bin/"
chmod +x "$REPO/bin/fm-copilot-hook.sh" "$REPO/bin/fm-arm-pretool-check.sh" "$REPO/bin/fm-operational-input.sh"
cat > "$REPO/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' LIVE_WATCHER_ARM_STARTED > .watch-arm-ran
sleep 1
printf '%s\n' signal: live copilot watcher > state/live.status
SH
chmod +x "$REPO/bin/fm-watch-arm.sh"

cat > "$REPO/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --ack-through ]; then
  count=0
  [ ! -f .wake-ack-count ] || count=$(cat .wake-ack-count)
  count=$((count + 1))
  printf '%s' "$count" > .wake-ack-count
  printf '%s\n' "$*" > .wake-ack-args
  exit 0
fi
count=0
[ ! -f .wake-drain-count ] || count=$(cat .wake-drain-count)
count=$((count + 1))
printf '%s' "$count" > .wake-drain-count
printf '%s\n' LIVE_WATCH_DRAINED
printf '%s\n' 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through live-seq'
SH
chmod +x "$REPO/bin/fm-wake-drain.sh"

cat > "$REPO/hooks/pretool-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
payload=$(cat)
printf '%s' "$payload" > .pretool-payload.json
printf '%s' "$payload" | ./bin/fm-copilot-hook.sh pretool-arm
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
payload=$(cat)
printf '%s' "$payload" > .notification-payload.json
printf '%s' "$payload" | ./bin/fm-copilot-hook.sh notification
SH
chmod +x "$REPO/hooks/notification.sh"

git -C "$REPO" add .
git -C "$REPO" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid \
  commit -qm initial

PRETOOL_PROMPT='Use the bash tool to run exactly: bin/fm-watch-arm.sh &. Then reply exactly: INITIAL_RESPONSE'
PRETOOL_OUT=$(cd "$REPO" && copilot -p "$PRETOOL_PROMPT" --allow-all --no-ask-user \
  --no-auto-update --no-remote --no-remote-export --add-dir "$REPO" --silent)
STATUS=$?
expect_code 0 "$STATUS" "Copilot live hook run should succeed"

assert_contains "$PRETOOL_OUT" "LIVE_SESSION_START_OK LIVE_AGENT_STOP_OK" \
  "agentStop did not force the expected continuation with sessionStart context"
assert_absent "$REPO/.watch-arm-ran" "preToolUse did not deny the protected watcher-arm command"
[ "$(cat "$REPO/.agent-stop-count" 2>/dev/null)" = 2 ] \
  || fail "agentStop did not run once to block and once to allow"
jq -e '(.source == "startup" or .source == "new") and (.sessionId | type) == "string"' \
  "$REPO/.session-start-payload.json" >/dev/null \
  || fail "sessionStart payload did not use the documented camelCase shape"
jq -e '.toolName == "bash" and (.toolArgs.command == "bin/fm-watch-arm.sh &")' \
  "$REPO/.pretool-payload.json" >/dev/null \
  || fail "preToolUse payload did not reach the shared Copilot watcher-arm policy path"
jq -e '.stopReason == "end_turn" and .stop_hook_active == true' \
  "$REPO/.agent-stop-payload.json" >/dev/null \
  || fail "the final agentStop payload did not report the bounded continuation"

WATCHER_PROMPT='Run exactly `bin/fm-watch-arm.sh` as its own attached asynchronous bash task and then stop. After a later Firstmate watcher wake arrives, follow that Firstmate watcher wake instruction exactly and then reply exactly LIVE_WATCH_NOTIFICATION_OK. Never run bin/fm-wake-drain.sh unless a Firstmate watcher wake tells you to.'
WATCHER_OUT=$(cd "$REPO" && copilot -p "$WATCHER_PROMPT" --allow-all --no-ask-user \
  --no-auto-update --no-remote --no-remote-export --add-dir "$REPO" --silent)
STATUS=$?
expect_code 0 "$STATUS" "Copilot watcher notification run should succeed"
assert_contains "$WATCHER_OUT" "LIVE_WATCH_NOTIFICATION_OK" \
  "the tracked watcher notification did not resume Copilot through the shared follow-up"
[ "$(cat "$REPO/.wake-drain-count" 2>/dev/null)" = 1 ] \
  || fail "Copilot did not run bin/fm-wake-drain.sh exactly once after the watcher notification"
[ "$(cat "$REPO/.wake-ack-count" 2>/dev/null)" = 1 ] \
  || fail "Copilot did not run the exact WAKE_ACK_REQUIRED acknowledgement after the watcher notification"
[ "$(cat "$REPO/.wake-ack-args" 2>/dev/null)" = '--ack-through live-seq' ] \
  || fail "Copilot did not use the exact WAKE_ACK_REQUIRED acknowledgement command"
jq -e '.notification_type == "shell_completed"' "$REPO/.notification-payload.json" >/dev/null \
  || fail "the watcher completion did not emit Copilot's shell_completed notification"

rm -f "$REPO/.wake-drain-count" "$REPO/.wake-ack-count" "$REPO/.wake-ack-args" "$REPO/.notification-payload.json"
UNRELATED_PROMPT='Run this exact bash command as an attached background task: sleep 1; printf LIVE_BACKGROUND_DONE > background-result. Wait for its completion notification and then reply exactly LIVE_UNRELATED_NOTIFICATION_OK. Never run bin/fm-wake-drain.sh unless a Firstmate watcher wake arrives.'
UNRELATED_OUT=$(cd "$REPO" && copilot -p "$UNRELATED_PROMPT" --allow-all --no-ask-user \
  --no-auto-update --no-remote --no-remote-export --add-dir "$REPO" --silent)
STATUS=$?
expect_code 0 "$STATUS" "Copilot unrelated notification run should succeed"
assert_contains "$UNRELATED_OUT" "LIVE_UNRELATED_NOTIFICATION_OK" \
  "an unrelated completion notification did not resume Copilot cleanly"
[ "$(cat "$REPO/background-result" 2>/dev/null)" = LIVE_BACKGROUND_DONE ] \
  || fail "the unrelated attached background shell task did not complete"
assert_absent "$REPO/.wake-drain-count" "an unrelated completion notification incorrectly triggered bin/fm-wake-drain.sh"
jq -e '.notification_type == "shell_completed"' "$REPO/.notification-payload.json" >/dev/null \
  || fail "the unrelated background completion did not emit Copilot's shell_completed notification"

version=$(copilot --version 2>/dev/null | head -1 | tr -d '\r')
pass "Copilot live hooks: denial, stop continuation, watcher wake, and inert unrelated notifications ($version)"
