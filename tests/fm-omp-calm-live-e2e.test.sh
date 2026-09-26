#!/usr/bin/env bash
# Token-free command regression against the installed OMP interactive terminal.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_OMP_CALM_LIVE omp tmux python3
TMP_ROOT=$(fm_test_tmproot fm-omp-calm-live)
SOCKET="fm-calm-live-$$"
cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/project" "$TMP_ROOT/agent"
cat > "$TMP_ROOT/agent/config.yml" <<'YAML'
startup:
  setupWizard: false
  checkUpdate: false
YAML
# Resume the public session format with a settled tool call; no model request runs.
python3 - "$TMP_ROOT/session.jsonl" "$TMP_ROOT/project" <<'PYTHON'
import json, sys
stamp = "2026-09-25T12:00:00.000Z"
entries = [{"type": "session", "version": 3, "id": "calm-live", "timestamp": stamp, "cwd": sys.argv[2]}]
messages = [
    {"role": "user", "content": "CALM_USER_VISIBLE", "timestamp": 0},
    {"role": "assistant", "content": [{"type": "toolCall", "id": "call1", "name": "bash", "arguments": {"command": "echo CALM_TOOL_VISIBLE"}}], "api": "openai-completions", "provider": "openai", "model": "gpt-4o", "usage": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0, "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}, "stopReason": "toolUse", "timestamp": 0},
    {"role": "toolResult", "toolCallId": "call1", "toolName": "bash", "content": [{"type": "text", "text": "CALM_TOOL_VISIBLE"}], "isError": False, "timestamp": 0},
    {"role": "user", "content": "CALM_END_VISIBLE", "timestamp": 0},
]
for i, message in enumerate(messages):
    entries.append({"type": "message", "id": str(i), "parentId": str(i - 1) if i else None, "timestamp": stamp, "message": message})
with open(sys.argv[1], "w") as f:
    for entry in entries:
        f.write(json.dumps(entry) + "\n")
PYTHON
cat > "$TMP_ROOT/run" <<SH2
#!/bin/sh
cd '$TMP_ROOT/project'
exec env -i PATH='$PATH' HOME='$TMP_ROOT/home' TERM=xterm-256color PI_CODING_AGENT_DIR='$TMP_ROOT/agent' \
  '$(command -v omp)' --resume '$TMP_ROOT/session.jsonl' --no-extensions --no-skills --no-rules --no-lsp --no-title \
  -e '$ROOT/extensions/fm-calm-omp/fm-calm-omp.ts'
SH2
chmod +x "$TMP_ROOT/run"
tmux -L "$SOCKET" -f /dev/null new-session -d -s calm -x 110 -y 32 "$TMP_ROOT/run"
wait_screen() {
  local expected=$1 i=0
  while [ "$i" -lt 60 ]; do
    tmux -L "$SOCKET" capture-pane -p -t calm > "$TMP_ROOT/screen"
    if grep -F "$expected" "$TMP_ROOT/screen" >/dev/null; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  cat "$TMP_ROOT/screen" >&2
  fail "OMP $(omp --version): missing $expected"
}
command_ui() {
  tmux -L "$SOCKET" send-keys -t calm -l "$1"
  tmux -L "$SOCKET" send-keys -t calm Enter
}
wait_screen 'CALM_TOOL_VISIBLE'
command_ui /calm-omp
wait_screen 'Tool activity: hidden'
! grep -F 'CALM_TOOL_VISIBLE' "$TMP_ROOT/screen" >/dev/null \
  || fail "hidden tool activity remains rendered"
grep -F 'CALM_USER_VISIBLE' "$TMP_ROOT/screen" >/dev/null \
  || fail "hiding tools removed the user message"
command_ui /calm-omp
wait_screen 'Tool activity: visible'
wait_screen 'CALM_TOOL_VISIBLE'
pass "OMP $(omp --version): /calm-omp hides and restores native tool activity"
