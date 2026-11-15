#!/usr/bin/env bash
# Token-free installed Claude Code guard for config/crew-exclude-tools.
#
# The hermetic suites pin the launch flag fm-spawn emits; only the real binary can
# prove that flag removes a tool's schema from the model request, which is the whole
# point of the exclusion. This guard launches the installed `claude` twice against a
# capture-only local server (tests/fixtures/fm-claude-request-capture.py) that records
# the request body and answers 529, so no model is called and no tokens are spent.
# The arms differ only in --disallowedTools, and the request's tool list must lose
# exactly the excluded tool's schema.
#
# The launch gets a clean environment, a private config directory and a synthetic API
# key, so it needs no Claude Code login and cannot reach any endpoint but the capture
# server, whatever provider variables the host sets. Enabled by default wherever claude
# and python3 are installed; FM_CLAUDE_TOOL_EXCLUDE_LIVE=1 makes an absent tool or a claude
# that sends no request a failure, and =0 skips.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_TOOL_EXCLUDE_LIVE claude python3

TMP_ROOT=$(fm_test_tmproot fm-claude-tool-exclude)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
CAPTURE_PID=''
stop_capture() {
  [ -z "$CAPTURE_PID" ] || kill "$CAPTURE_PID" 2>/dev/null || true
  CAPTURE_PID=''
}
# lib.sh's own EXIT trap is fm_test_cleanup; this one replaces it, so it must run it too.
trap 'stop_capture; fm_test_cleanup' EXIT

# unusable <reason>: skip when the host cannot run the comparison, fail when it was requested.
unusable() {
  if [ "${FM_CLAUDE_TOOL_EXCLUDE_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "$1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

# capture_tools <label> [claude args...]: write the main request's tool names, one per line,
# to $TMP_ROOT/<label>.tools. Runs in the main shell so unusable can end the script.
capture_tools() {
  local label=$1 port_file capture port
  shift
  port_file=$TMP_ROOT/$label.port
  capture=$TMP_ROOT/$label.jsonl
  python3 "$ROOT/tests/fixtures/fm-claude-request-capture.py" "$port_file" "$capture" &
  CAPTURE_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$port_file" ] && break
    sleep 0.1
  done
  [ -s "$port_file" ] || fail "the capture server did not start for $label"
  port=$(cat "$port_file")
  # A clean environment, a private config directory and a synthetic key leave the
  # capture server as the only endpoint this launch can reach: no inherited
  # Bedrock, Vertex, proxy or login setting can send "say hi" to a real model.
  (
    cd "$TMP_ROOT" || exit 1
    fm_run_timed 40 env -i PATH="$PATH" HOME="$TMP_ROOT/home" TERM=dumb \
      CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config" \
      ANTHROPIC_API_KEY=sk-ant-synthetic-capture-only \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
      DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p "say hi" --max-turns 1 "$@" >/dev/null 2>&1 || true
  )
  stop_capture
  [ -s "$capture" ] || unusable "claude $CLAUDE_VERSION sent no model request for $label"
  python3 -I - "$capture" >"$TMP_ROOT/$label.tools" <<'PY'
import json, sys
best = []
for line in open(sys.argv[1]):
    try:
        names = [t["name"] for t in json.loads(line).get("tools", [])]
    except ValueError:
        continue
    if len(names) > len(best):
        best = names
print("\n".join(best))
PY
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

capture_tools baseline
capture_tools trimmed --disallowedTools Workflow
baseline=$(cat "$TMP_ROOT/baseline.tools")
trimmed=$(cat "$TMP_ROOT/trimmed.tools")

printf '%s\n' "$baseline" | grep -qx Workflow \
  || unusable "claude $CLAUDE_VERSION baseline request does not carry Workflow, so the comparison proves nothing"
printf '%s\n' "$trimmed" | grep -qx Workflow \
  && fail "claude $CLAUDE_VERSION still sends the Workflow schema under --disallowedTools"
[ "$(printf '%s\n' "$baseline" | grep -vx Workflow | sort | tr '\n' ' ')" = "$(printf '%s\n' "$trimmed" | sort | tr '\n' ' ')" ] \
  || fail "claude $CLAUDE_VERSION changed more than the excluded tool's schema"
pass "Claude Code $CLAUDE_VERSION: --disallowedTools removes exactly the excluded tool's schema from the model request"
