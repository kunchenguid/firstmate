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
# Enabled by default wherever claude and python3 are installed; FM_CLAUDE_TOOL_EXCLUDE_LIVE=1
# makes an absent tool a failure and =0 skips. It needs a Claude Code login only to
# get as far as building a request.
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
trap 'stop_capture' EXIT

# capture_tools <label> [claude args...]: print the main request's tool names, one per line.
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
  (
    cd "$TMP_ROOT" || exit 1
    ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
      fm_run_timed 40 claude -p "say hi" --max-turns 1 "$@" >/dev/null 2>&1 || true
  )
  stop_capture
  [ -s "$capture" ] || fail "claude $CLAUDE_VERSION sent no model request for $label; is it logged in?"
  python3 -I - "$capture" <<'PY'
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

baseline=$(capture_tools baseline)
trimmed=$(capture_tools trimmed --disallowedTools Workflow)

printf '%s\n' "$baseline" | grep -qx Workflow \
  || fail "claude $CLAUDE_VERSION baseline request does not carry Workflow, so the comparison proves nothing"
printf '%s\n' "$trimmed" | grep -qx Workflow \
  && fail "claude $CLAUDE_VERSION still sends the Workflow schema under --disallowedTools"
[ "$(printf '%s\n' "$baseline" | grep -vx Workflow | sort | tr '\n' ' ')" = "$(printf '%s\n' "$trimmed" | sort | tr '\n' ' ')" ] \
  || fail "claude $CLAUDE_VERSION changed more than the excluded tool's schema"
pass "Claude Code $CLAUDE_VERSION: --disallowedTools removes exactly the excluded tool's schema from the model request"
