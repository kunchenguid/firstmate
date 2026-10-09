#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for config/claude-denied-mcp-servers
# (bin/fm-claude-mcp-deny-lib.sh, folded into bin/fm-spawn.sh's claude ship and
# scout --settings JSON).
# `deniedMcpServers` is a vendor settings key whose merge and matching rules,
# including the `plugin:<plugin>:<server>` name Claude Code gives a plugin's
# server, only the real binary can confirm, so a stub could only echo back the
# assumption. This guard builds a throwaway plugin and an --mcp-config file that
# declare two stdio servers with the same name, then runs two real `claude -p`
# sessions in the installed Claude Code: the baseline must start both servers,
# and the session carrying the fragment the library builds from a denylist file
# naming the plugin's copy must start only the --mcp-config one.
# Each session submits a trivial prompt, so this guard spends model tokens and
# stays opt-in. Claude keeps using its existing managed authentication; no live
# fleet home, worktree, or session is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-claude-mcp-deny-lib.sh
. "$ROOT/bin/fm-claude-mcp-deny-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

CLAUDE_VERSION=$(claude --version)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-mcp-deny.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
cleanup() {
  pkill -f "$LAB/server.sh" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# Each server is a long-lived stdio process whose argument names its copy, so
# the process table shows which declarations Claude actually started.
mkdir -p "$LAB/plugin/.claude-plugin" "$LAB/work" "$LAB/config"
cat >"$LAB/server.sh" <<'SH'
#!/bin/sh
i=0
while [ "$i" -lt 60 ]; do
  sleep 0.5
  i=$((i + 1))
done
SH
chmod +x "$LAB/server.sh"
printf '{"name":"fm-deny-probe","version":"0.0.1"}\n' >"$LAB/plugin/.claude-plugin/plugin.json"
printf '{"mcpServers":{"probe":{"command":"%s","args":["plugin-copy"]}}}\n' "$LAB/server.sh" >"$LAB/plugin/.mcp.json"
printf '{"mcpServers":{"probe":{"command":"%s","args":["config-copy"]}}}\n' "$LAB/server.sh" >"$LAB/mcp.json"

printf '# the plugin copy of a duplicated server\nplugin:fm-deny-probe:probe\n' >"$LAB/config/claude-denied-mcp-servers"
fragment=$(fm_claude_denied_mcp_servers_json "$LAB/config") || fail "the denylist library rejected a valid file"
[ -n "$fragment" ] || fail "the denylist library built no fragment from a non-empty file"

servers_started() {  # <settings-json> <out-file>
  local settings=$1 out=$2 pid pids
  : >"$out"
  (cd "$LAB/work" && claude -p --plugin-dir "$LAB/plugin" --settings "$settings" \
    --mcp-config "$LAB/mcp.json" -- 'Run no tools. Reply with the single word ok.' \
    >"$LAB/claude.out" 2>&1) &
  pid=$!
  for _ in $(seq 1 60); do
    sleep 0.5
    pids=$(pgrep -d, -f "$LAB/server.sh" || true)
    [ -z "$pids" ] || ps -o args= -p "$pids" >>"$out" 2>/dev/null || true
    kill -0 "$pid" 2>/dev/null || break
  done
  wait "$pid" || fail "claude -p failed under $CLAUDE_VERSION: $(cat "$LAB/claude.out")"
  pkill -f "$LAB/server.sh" 2>/dev/null || true
}

servers_started '{"feedbackDrafts":"off"}' "$LAB/baseline"
servers_started "{\"feedbackDrafts\":\"off\"$fragment}" "$LAB/denied"

if ! grep -q 'plugin-copy' "$LAB/baseline" || ! grep -q 'config-copy' "$LAB/baseline"; then
  fail "baseline session under $CLAUDE_VERSION did not start both probe servers, so the denied run would prove nothing: $(sort -u "$LAB/baseline")"
fi
grep -q 'config-copy' "$LAB/denied" || fail \
  "claude $CLAUDE_VERSION denied the --mcp-config server too: $(sort -u "$LAB/denied")"
grep -q 'plugin-copy' "$LAB/denied" && fail \
  "claude $CLAUDE_VERSION ignored the deniedMcpServers entry for plugin:fm-deny-probe:probe: $(sort -u "$LAB/denied")"

printf 'ok - %s: a config/claude-denied-mcp-servers entry stops only the named plugin server\n' "$CLAUDE_VERSION"
