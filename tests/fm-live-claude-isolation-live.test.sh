#!/usr/bin/env bash
# Token-free installed Claude Code guard for the flags every live test passes when it starts
# a fixture Claude session: --setting-sources project,local --settings "$FM_LIVE_CLAUDE_SETTINGS".
#
# Without them a fixture session inherits the caller's user settings, so every user-scope
# plugin and hook runs on the fixture's prompts. This guard installs a marker plugin and a
# marker hook at user scope in a private config directory, gives the fixture project its own
# hook, and requires that the flags keep the project hook and drop both user-scope markers.
# User settings also carry the bypass-mode acceptance, so it also requires that an
# interactive --dangerously-skip-permissions launch with the flags opens without the
# bypass warning.
#
# Every launch gets a clean environment, the private config directory, a synthetic API key
# and the capture-only server (tests/fixtures/fm-claude-request-capture.py), so it needs no
# login and no model is called. Enabled by default wherever claude, jq, python3 and tmux are
# installed; FM_LIVE_CLAUDE_ISOLATION_LIVE=1 makes an absent tool a failure, and =0 skips.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_CLAUDE_ISOLATION_LIVE claude jq python3 tmux

TMP_ROOT=$(fm_test_tmproot fm-live-claude-isolation)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
CONFIG=$TMP_ROOT/claude-config
PROJECT=$TMP_ROOT/project
KEY=sk-ant-synthetic-capture-only
SOCKET=fm-live-claude-isolation-$$
CAPTURE_PID=''
stop_capture() {
  [ -z "$CAPTURE_PID" ] || kill "$CAPTURE_PID" 2>/dev/null || true
  CAPTURE_PID=''
}
# lib.sh's own EXIT trap is fm_test_cleanup; this one replaces it, so it must run it too.
trap 'stop_capture; tmux -L "$SOCKET" kill-server 2>/dev/null || true; fm_test_cleanup' EXIT

# fixture_env <marker-dir>: the clean environment every launch gets, as an `env -i` prefix in FIXTURE_ENV.
fixture_env() {
  FIXTURE_ENV=(env -i PATH="$PATH" HOME="$TMP_ROOT/home" TERM=xterm-256color
    CLAUDE_CONFIG_DIR="$CONFIG" MARKER_OUT="$1" ANTHROPIC_API_KEY="$KEY"
    ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
}
fixture_claude() {  # <marker-dir> [claude args...]
  fixture_env "$1"
  shift
  fm_run_timed 60 "${FIXTURE_ENV[@]}" claude "$@"
}

marker_hooks() {  # <log name>
  jq -n --arg log "$1" '{SessionStart: [{hooks: [{type: "command", command: ("echo SessionStart >> \"$MARKER_OUT/" + $log + "\"")}]}],
    UserPromptSubmit: [{hooks: [{type: "command", command: ("echo UserPromptSubmit >> \"$MARKER_OUT/" + $log + "\"")}]}]}'
}

mkdir -p "$TMP_ROOT/home" "$CONFIG" "$PROJECT/.claude" \
  "$TMP_ROOT/market/.claude-plugin" "$TMP_ROOT/market/marker/.claude-plugin" "$TMP_ROOT/market/marker/hooks"
printf '%s\n' '{"name":"fixture-market","owner":{"name":"fixture"},"plugins":[{"name":"marker","source":"./marker"}]}' \
  > "$TMP_ROOT/market/.claude-plugin/marketplace.json"
printf '%s\n' '{"name":"marker","version":"0.0.1"}' > "$TMP_ROOT/market/marker/.claude-plugin/plugin.json"
marker_hooks user-plugin.log | jq '{hooks: .}' > "$TMP_ROOT/market/marker/hooks/hooks.json"
marker_hooks project.log | jq '{hooks: .}' > "$PROJECT/.claude/settings.json"

python3 "$ROOT/tests/fixtures/fm-claude-request-capture.py" "$TMP_ROOT/port" "$TMP_ROOT/capture.jsonl" &
CAPTURE_PID=$!
for _ in $(seq 1 50); do
  [ -s "$TMP_ROOT/port" ] && break
  sleep 0.1
done
[ -s "$TMP_ROOT/port" ] || fail "the capture server did not start"
PORT=$(cat "$TMP_ROOT/port")

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

# A user-scope plugin installed the way an operator installs one, plus a plain user hook and
# the bypass-mode acceptance an operator's user settings hold.
( cd "$TMP_ROOT" && fixture_claude "$TMP_ROOT" plugin marketplace add "$TMP_ROOT/market" >/dev/null 2>&1 ) \
  || fail "claude $CLAUDE_VERSION could not add the fixture marketplace"
( cd "$TMP_ROOT" && fixture_claude "$TMP_ROOT" plugin install marker@fixture-market --scope user >/dev/null 2>&1 ) \
  || fail "claude $CLAUDE_VERSION could not install the fixture plugin at user scope"
jq --argjson hooks "$(marker_hooks user-settings.log)" '. + {hooks: $hooks, skipDangerousModePermissionPrompt: true}' \
  "$CONFIG/settings.json" > "$CONFIG/settings.json.new" && mv "$CONFIG/settings.json.new" "$CONFIG/settings.json"
jq --arg project "$PROJECT" --arg key "${KEY: -20}" '. + {hasCompletedOnboarding: true, theme: "dark",
    customApiKeyResponses: {approved: [$key], rejected: []}} | .projects[$project].hasTrustDialogAccepted = true' \
  "$CONFIG/.claude.json" > "$CONFIG/.claude.json.new" && mv "$CONFIG/.claude.json.new" "$CONFIG/.claude.json"

run_print() {  # <label> [claude args...]
  local out=$TMP_ROOT/$1
  shift
  mkdir -p "$out"
  ( cd "$PROJECT" && fixture_claude "$out" -p "say hi" --max-turns 1 "$@" >/dev/null 2>&1 ) || true
}
fired() { [ "$(sort "$TMP_ROOT/$1/$2" 2>/dev/null | tr '\n' ' ')" = "SessionStart UserPromptSubmit " ]; }

run_print baseline
fired baseline user-plugin.log \
  || fail "claude $CLAUDE_VERSION never ran the user-scope marker plugin without the flags, so the comparison proves nothing"
fired baseline user-settings.log \
  || fail "claude $CLAUDE_VERSION never ran the user-settings marker hook without the flags, so the comparison proves nothing"


run_print isolated "${FM_LIVE_CLAUDE_FLAGS[@]}"
fired isolated project.log || fail "claude $CLAUDE_VERSION dropped the fixture project's own hooks under the live-test flags"
[ ! -e "$TMP_ROOT/isolated/user-plugin.log" ] || fail "claude $CLAUDE_VERSION still ran the user-scope plugin under the live-test flags"
[ ! -e "$TMP_ROOT/isolated/user-settings.log" ] || fail "claude $CLAUDE_VERSION still ran the user-settings hook under the live-test flags"

mkdir -p "$TMP_ROOT/interactive"
fixture_env "$TMP_ROOT/interactive"

tmux -L "$SOCKET" new-session -d -s fixture -x 160 -y 40 -c "$PROJECT" \
  "${FIXTURE_ENV[@]}" claude --dangerously-skip-permissions "${FM_LIVE_CLAUDE_FLAGS[@]}" \
  || fail "the interactive fixture session did not start"
screen=''
for _ in $(seq 1 60); do
  screen=$(tmux -L "$SOCKET" capture-pane -p -t fixture 2>/dev/null || true)
  case "$screen" in
    *'Bypass Permissions mode'*) fail "claude $CLAUDE_VERSION stopped at the bypass-mode warning under the live-test flags" ;;
    *'bypass permissions on'*) break ;;
  esac
  sleep 0.5
done
case "$screen" in
  *'bypass permissions on'*) ;;
  *) fail "claude $CLAUDE_VERSION never reached its prompt in bypass mode under the live-test flags; last screen: $(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -n 6)" ;;
esac

pass "Claude Code $CLAUDE_VERSION: the live-test flags keep the fixture's project hooks, drop user-scope plugins and hooks, and keep bypass mode without its warning"
