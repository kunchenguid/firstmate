#!/usr/bin/env bash
# Token-free installed Claude Code guard for the claudeMdExcludes patterns a Claude
# secondmate's --settings file carries (bin/fm-claude-project-memory-lib.sh).
#
# The hermetic suites pin the patterns fm-spawn writes; only the real binary can prove
# Claude Code honors them. This guard builds a throwaway home that itself sits under a
# directory named projects, with one clone holding a CLAUDE.md and an unconditional rule,
# and launches the installed `claude` against a scripted local server
# (tests/fixtures/fm-claude-read-replay.py) that asks for one Read of a file inside the
# clone and records every request, so no model is called and no tokens are spent.
# Without the patterns, the request that carries the Read result must carry the clone's
# instructions, or the comparison proves nothing; with them, it must not, and the home's
# own CLAUDE.md must still reach the session.
#
# The launch gets a clean environment, a private config directory and a synthetic API
# key, so it needs no Claude Code login and cannot reach any endpoint but the scripted
# server, whatever provider variables the host sets. Enabled by default wherever claude,
# python3 and jq are installed; FM_CLAUDE_PROJECT_MEMORY_LIVE=1 makes an absent tool or a
# claude that sends no request a failure, and =0 skips.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_PROJECT_MEMORY_LIVE claude python3 jq

TMP_ROOT=$(fm_test_tmproot fm-claude-project-memory)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
SERVER_PID=''
stop_server() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=''
}
# lib.sh's own EXIT trap is fm_test_cleanup; this one replaces it, so it must run it too.
trap 'stop_server; fm_test_cleanup' EXIT

# unusable <reason>: skip when the host cannot run the comparison, fail when it was requested.
unusable() {
  if [ "${FM_CLAUDE_PROJECT_MEMORY_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "$1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-claude-project-memory-lib.sh
. "$ROOT/bin/fm-claude-project-memory-lib.sh"

HOME_MARKER=fm-home-own-instructions-marker
CLONE_MARKER=fm-clone-instructions-marker
RULE_MARKER=fm-clone-rule-marker

home_dir=$TMP_ROOT/projects/home
clone=$home_dir/projects/app
mkdir -p "$clone/src" "$clone/.claude/rules"
printf '%s\n' "$HOME_MARKER" > "$home_dir/CLAUDE.md"
printf '%s\n' "$CLONE_MARKER" > "$clone/CLAUDE.md"
printf '%s\n' "$RULE_MARKER" > "$clone/.claude/rules/always.md"
printf 'clone file\n' > "$clone/src/file.txt"
git -C "$home_dir" init -q
git -C "$clone" init -q
read_path="$(cd "$clone/src" && pwd -P)/file.txt"

excludes=$(fm_claude_project_memory_excludes "$home_dir") \
  || fail "fm_claude_project_memory_excludes refused the test home $home_dir"
jq -n --argjson excludes "$excludes" '{claudeMdExcludes: $excludes}' > "$TMP_ROOT/excludes.json"

# run_arm <label> [claude args...]: let the scripted server ask for one Read inside the
# clone, and write which markers reached the session to $TMP_ROOT/<label>.flags as
# "home clone rule" flags (1 or 0): the home marker in any request, the clone markers in
# the request carrying the Read result. Runs in the main shell so unusable can end the
# script and the EXIT trap can stop the server.
run_arm() {
  local label=$1 port_file capture port
  shift
  port_file=$TMP_ROOT/$label.port
  capture=$TMP_ROOT/$label.jsonl
  python3 "$ROOT/tests/fixtures/fm-claude-read-replay.py" "$port_file" "$capture" "$read_path" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$port_file" ] && break
    sleep 0.1
  done
  [ -s "$port_file" ] || fail "the scripted server did not start for $label"
  port=$(cat "$port_file")
  (
    cd "$home_dir" || exit 1
    fm_run_timed 60 env -i PATH="$PATH" HOME="$TMP_ROOT/user-home" TERM=dumb \
      CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config-$label" \
      ANTHROPIC_API_KEY=sk-ant-synthetic-capture-only \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
      DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p "read the file" --max-turns 3 --allowedTools Read "$@" </dev/null >/dev/null 2>&1 || true
  )
  stop_server
  [ -s "$capture" ] || unusable "claude $CLAUDE_VERSION sent no model request for $label"
  python3 -I - "$capture" "$HOME_MARKER" "$CLONE_MARKER" "$RULE_MARKER" >"$TMP_ROOT/$label.flags" <<'PY'
import json, sys
capture, home, clone, rule = sys.argv[1:5]
seen_home = seen_result = seen_clone = seen_rule = False
for line in open(capture):
    seen_home = seen_home or home in line
    try:
        messages = json.loads(line).get("messages", [])
    except ValueError:
        continue
    if '"tool_result"' in json.dumps(messages):
        seen_result = True
        seen_clone = seen_clone or clone in line
        seen_rule = seen_rule or rule in line
if not seen_result:
    print("no-read")
else:
    print(" ".join(str(int(flag)) for flag in (seen_home, seen_clone, seen_rule)))
PY
}

run_arm baseline
baseline=$(cat "$TMP_ROOT/baseline.flags")
[ "$baseline" != no-read ] \
  || unusable "claude $CLAUDE_VERSION did not run the scripted Read without the patterns"
[ "$baseline" = "1 1 1" ] \
  || unusable "claude $CLAUDE_VERSION loaded no clone instructions on a read without the patterns (home clone rule: $baseline), so the comparison proves nothing"

run_arm excluded --settings "$TMP_ROOT/excludes.json"
excluded=$(cat "$TMP_ROOT/excluded.flags")
[ "$excluded" != no-read ] \
  || unusable "claude $CLAUDE_VERSION did not run the scripted Read under the patterns"
case $excluded in
1\ 0\ 0) ;;
0\ *) fail "claude $CLAUDE_VERSION lost the home's own CLAUDE.md under the project-memory patterns (home clone rule: $excluded)" ;;
*) fail "claude $CLAUDE_VERSION still loads the clone's instructions under claudeMdExcludes from --settings (home clone rule: $excluded)" ;;
esac
pass "Claude Code $CLAUDE_VERSION: the --settings project-memory patterns keep a clone's CLAUDE.md and rules out while the home's own CLAUDE.md loads"
