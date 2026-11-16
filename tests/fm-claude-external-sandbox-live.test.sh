#!/usr/bin/env bash
# Token-free installed Claude Code guard for the external worker sandbox
# (bin/fm-external-sandbox-lib.sh, docs/configuration.md "External workers").
#
# The hermetic suite pins the settings fm-spawn writes; only the real binary can
# prove those settings contain a worker. This guard launches the installed
# `claude` under --dangerously-skip-permissions, Firstmate's default posture,
# against a scripted local stand-in for the model API
# (tests/fixtures/fm-claude-scripted-tools.py) that answers with fixed tool
# calls and records what the real client and its sandbox returned. No model is
# called and no tokens are spent.
#
# Two loopback servers stand in for the network: one is on the allowlist, one is
# not. The sandbox exempts loopback from its proxy variables, so the HTTP steps
# pass --noproxy '' to send loopback through the sandbox proxy the way every
# outside host goes, and a direct socket step checks the path around the proxy. The contained arm must refuse the secret file, the unlisted server (by
# proxy-aware and by direct connection), and a write outside the granted paths
# from Bash and from the Write tool, while it still reaches the listed server
# and writes the granted path and the working directory, so a
# sandbox that simply breaks everything cannot pass. A control arm without
# network.strictAllowlist must reach the unlisted server, which proves the
# strict key is what closes the network and keeps the guard from going vacuous.
#
# The launch gets a clean environment, a private config directory and a
# synthetic API key, so it needs no Claude Code login and cannot reach any model.
# Enabled by default wherever claude, python3, jq and curl are installed;
# FM_CLAUDE_EXTERNAL_SANDBOX_LIVE=1 makes an absent tool or an unusable host a
# failure, and =0 skips.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_EXTERNAL_SANDBOX_LIVE claude python3 jq curl

# shellcheck source=bin/fm-external-sandbox-lib.sh
. "$ROOT/bin/fm-external-sandbox-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-external-sandbox)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
PIDS=()
stop_servers() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
  PIDS=()
}
# lib.sh's own EXIT trap is fm_test_cleanup; this one replaces it, so it must run it too.
trap 'stop_servers; fm_test_cleanup' EXIT

# unusable <reason>: skip when the host cannot run the guard, fail when it was requested.
unusable() {
  if [ "${FM_CLAUDE_EXTERNAL_SANDBOX_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "$1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

# wait_port <port-file>: print the port once the server wrote it.
wait_port() {
  local _
  for _ in $(seq 1 50); do
    [ -s "$1" ] && break
    sleep 0.1
  done
  [ -s "$1" ] || fail "a loopback server did not start ($1)"
  cat "$1"
}

# start_target <label>: start a loopback HTTP server that answers
# "reached-<label>" and writes its port to $TMP_ROOT/<label>.port. It runs in
# this shell, never inside a command substitution, so its pid is kept and the
# substitution never waits on the server's output.
start_target() {
  local label=$1
  python3 -I -c '
import http.server, sys
label, port_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = ("reached-" + label + "\n").encode()
        self.send_response(200); self.send_header("content-length", str(len(body))); self.end_headers()
        self.wfile.write(body)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
' "$label" "$TMP_ROOT/$label.port" >/dev/null 2>&1 &
  PIDS+=("$!")
}

start_target listed
start_target unlisted
LISTED_PORT=$(wait_port "$TMP_ROOT/listed.port")
UNLISTED_PORT=$(wait_port "$TMP_ROOT/unlisted.port")

WORK=$TMP_ROOT/work
mkdir -p "$WORK" "$TMP_ROOT/granted" "$TMP_ROOT/outside"
git init --quiet -b main "$WORK"
printf 'SECRET=canary-secret-value\n' > "$WORK/.env"

STEPS=(
  "cat .env"
  "curl -sS -m 5 --noproxy '' http://127.0.0.1:$UNLISTED_PORT/"
  "python3 -c \"import socket;socket.create_connection(('127.0.0.1',$UNLISTED_PORT),timeout=5);print('direct'+'-connected')\""
  "curl -sS -m 5 --noproxy '' http://127.0.0.1:$LISTED_PORT/"
  "echo x > '$TMP_ROOT/outside/file' && echo outside-wr''itten"
  "echo y > '$TMP_ROOT/granted/file' && echo granted-wr''itten"
  "tool:{\"name\":\"Write\",\"input\":{\"file_path\":\"$TMP_ROOT/outside/tool-file\",\"content\":\"x\"}}"
  "tool:{\"name\":\"Write\",\"input\":{\"file_path\":\"$WORK/tool-file\",\"content\":\"x\"}}"
)

# run_arm <label> <settings-json>: run the scripted steps under these settings;
# the results land in $TMP_ROOT/<label>.results, one JSON line per step.
run_arm() {
  local label=$1 settings=$2 api_port
  printf '%s\n' "$settings" > "$TMP_ROOT/$label.settings.json"
  : > "$TMP_ROOT/$label.results"
  python3 -I "$ROOT/tests/fixtures/fm-claude-scripted-tools.py" \
    "$TMP_ROOT/$label.api-port" "$TMP_ROOT/$label.results" "${STEPS[@]}" >/dev/null 2>&1 &
  PIDS+=("$!")
  api_port=$(wait_port "$TMP_ROOT/$label.api-port")
  (
    cd "$WORK" || exit 1
    fm_run_timed 120 env -i PATH="$PATH" HOME="$TMP_ROOT/home" TERM=dumb \
      CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config-$label" \
      ANTHROPIC_API_KEY=sk-ant-synthetic-scripted-only \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$api_port" \
      DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p "run the scripted steps" --max-turns 20 --dangerously-skip-permissions \
      --settings "$TMP_ROOT/$label.settings.json" "$FM_EXTERNAL_CLAUDE_FLAGS" \
      >"$TMP_ROOT/$label.out" 2>&1 || true
  )
  [ "$(wc -l < "$TMP_ROOT/$label.results" | tr -d ' ')" -eq "${#STEPS[@]}" ] \
    || unusable "claude $CLAUDE_VERSION did not run every scripted step for $label ($(head -c 400 "$TMP_ROOT/$label.out"))"
}

# step_output <label> <index>: the recorded tool output of one step.
step_output() {
  sed -n "$(($2 + 1))p" "$TMP_ROOT/$1.results" | jq -r .content
}

CONTAINED=$(fm_external_settings_json 0 "127.0.0.1:$LISTED_PORT" "$TMP_ROOT/granted" "")
run_arm contained "$CONTAINED"
grep -q 'sandbox' "$TMP_ROOT/contained.out" && grep -qi 'unavailable\|not available\|cannot start' "$TMP_ROOT/contained.out" \
  && unusable "claude $CLAUDE_VERSION reports its sandbox unavailable on this host"

assert_not_contains "$(step_output contained 0)" "canary-secret-value" \
  "claude $CLAUDE_VERSION let the contained worker read .env"
assert_not_contains "$(step_output contained 1)" "reached-unlisted" \
  "claude $CLAUDE_VERSION let the contained worker reach a host outside the allowlist"
assert_not_contains "$(step_output contained 2)" "direct-connected" \
  "claude $CLAUDE_VERSION let the contained worker open a direct connection outside the allowlist"
assert_contains "$(step_output contained 3)" "reached-listed" \
  "claude $CLAUDE_VERSION blocked the allowlisted host too, so the network check proves nothing"
assert_not_contains "$(step_output contained 4)" "outside-written" \
  "claude $CLAUDE_VERSION let the contained worker write outside its granted paths"
[ ! -e "$TMP_ROOT/outside/file" ] || fail "claude $CLAUDE_VERSION wrote outside the granted paths"
assert_contains "$(step_output contained 5)" "granted-written" \
  "claude $CLAUDE_VERSION refused the granted write path"
[ ! -e "$TMP_ROOT/outside/tool-file" ] || fail "claude $CLAUDE_VERSION let the Write tool write outside the working directories"
[ -e "$WORK/tool-file" ] || fail "claude $CLAUDE_VERSION refused a Write tool write inside the working directory"

CONTROL=$(printf '%s' "$CONTAINED" | jq -c 'del(.sandbox.network.strictAllowlist)')
run_arm control "$CONTROL"
assert_contains "$(step_output control 1)" "reached-unlisted" \
  "claude $CLAUDE_VERSION closed the network without network.strictAllowlist, so this guard no longer proves that key is load-bearing; re-measure and update the guard"

pass "Claude Code $CLAUDE_VERSION: the external worker sandbox refuses .env, unlisted hosts, and outside writes under bypass, and network.strictAllowlist is what closes the network"
