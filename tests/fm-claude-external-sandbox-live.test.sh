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
# sandbox that simply breaks everything cannot pass. It must also refuse a
# planted gh credential store, a .env outside the working directory, writes to
# a read-only --add-dir directory such as Firstmate's skills, to the working
# directory's .claude/settings.json, to a granted gate repository's hooks, and
# to every git link and config file fm_external_git_paths refuses in the shared
# git directory, the worktree's own admin directory, another worktree's admin
# directory, and the gate, while that directory stays readable and a commit in
# the linked worktree and a push to the gate still succeed. A hook the checkout's own
# .claude/settings.json names must not run, while the busy hook the --settings
# file carries does. A control arm without network.strictAllowlist and without
# --setting-sources user must reach the unlisted server and run the checkout's
# hook, which proves those two settings are what close the network and the
# project settings, and keeps the guard from going vacuous.
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
SKILLS=$TMP_ROOT/skills
GATE=$TMP_ROOT/gate.git
MAIN=$TMP_ROOT/main
git init --quiet -b main "$MAIN"
git -C "$MAIN" -c user.name=guard -c user.email=guard@example.invalid commit --quiet --allow-empty -m base
git -C "$MAIN" worktree add --quiet -b task "$WORK"
git -C "$MAIN" worktree add --quiet -b other "$TMP_ROOT/other"
git init --quiet --bare "$GATE"
COMMON=$(cd "$MAIN/.git" && pwd -P)
ADMIN=$(cd "$COMMON/worktrees/work" && pwd -P)
mkdir -p "$WORK/.claude" "$TMP_ROOT/granted" "$TMP_ROOT/outside" "$SKILLS" "$TMP_ROOT/home/.config/gh"
printf 'SECRET=canary-outside-value\n' > "$TMP_ROOT/outside/.env"
printf 'SECRET=canary-secret-value\n' > "$WORK/.env"
printf 'github.com:\n    oauth_token: canary-gh-token\n' > "$TMP_ROOT/home/.config/gh/hosts.yml"
printf 'skill-body\n' > "$SKILLS/SKILL.md"
PROJECT_HOOK=$(jq -nc --arg cmd "touch '$TMP_ROOT/project-hook-fired'" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: $cmd}]}], UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}]}}')
printf '%s\n' "$PROJECT_HOOK" > "$WORK/.claude/settings.json"
OWN_HOOK=$(jq -nc --arg cmd "touch '$TMP_ROOT/own-hook-fired'" \
  '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}]}}')

STEPS=(
  "cat .env"
  "curl -sS -m 5 --noproxy '' http://127.0.0.1:$UNLISTED_PORT/"
  "python3 -c \"import socket;socket.create_connection(('127.0.0.1',$UNLISTED_PORT),timeout=5);print('direct'+'-connected')\""
  "curl -sS -m 5 --noproxy '' http://127.0.0.1:$LISTED_PORT/"
  "echo x > '$TMP_ROOT/outside/file' && echo outside-wr''itten"
  "echo y > '$TMP_ROOT/granted/file' && echo granted-wr''itten"
  "tool:{\"name\":\"Write\",\"input\":{\"file_path\":\"$TMP_ROOT/outside/tool-file\",\"content\":\"x\"}}"
  "tool:{\"name\":\"Write\",\"input\":{\"file_path\":\"$WORK/tool-file\",\"content\":\"x\"}}"
  "cat '$TMP_ROOT/home/.config/gh/hosts.yml'"
  "cat '$SKILLS/SKILL.md'"
  "echo z > '$SKILLS/SKILL.md' && echo skills-wr''itten"
  "tool:{\"name\":\"Write\",\"input\":{\"file_path\":\"$SKILLS/tool-file\",\"content\":\"x\"}}"
  "echo '{}' > .claude/settings.json && echo settings-wr''itten"
  "tool:{\"name\":\"Write\",\"input\":{\"file_path\":\"$WORK/.claude/settings.json\",\"content\":\"{}\"}}"
  "echo x > '$GATE/hooks/post-checkout' && echo gate-hook-wr''itten"
  "echo y > '$GATE/objects/probe' && echo gate-wr''itten"
  "cat '$TMP_ROOT/outside/.env'"
  "tool:{\"name\":\"Read\",\"input\":{\"file_path\":\"$TMP_ROOT/outside/.env\"}}"
  "git add tool-file && git -c user.name=guard -c user.email=guard@example.invalid commit --quiet -m probe && echo commit-o''k"
  "git push --quiet '$GATE' HEAD:refs/heads/probe && echo push-o''k"
  "echo x > '$COMMON/commondir' && echo common-link-wr''itten"
  "echo x > '$ADMIN/commondir' && echo admin-link-wr''itten"
  "echo x > '$ADMIN/config.worktree' && echo admin-config-wr''itten"
  "echo x > '$COMMON/worktrees/other/commondir' && echo other-link-wr''itten"
  "echo x > '$GATE/commondir' && echo gate-link-wr''itten"
)

# run_arm <label> <settings-json> <launch-flag>...: run the scripted steps
# under these settings and flags; the results land in
# $TMP_ROOT/<label>.results, one JSON line per step.
run_arm() {
  local label=$1 settings=$2 api_port
  shift 2
  rm -f "$TMP_ROOT/project-hook-fired" "$TMP_ROOT/own-hook-fired"
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
      claude -p "run the scripted steps" --max-turns 40 --dangerously-skip-permissions \
      --settings "$TMP_ROOT/$label.settings.json" --add-dir "$SKILLS" "$@" \
      >"$TMP_ROOT/$label.out" 2>&1 || true
  )
  [ "$(wc -l < "$TMP_ROOT/$label.results" | tr -d ' ')" -eq "${#STEPS[@]}" ] \
    || unusable "claude $CLAUDE_VERSION did not run every scripted step for $label ($(head -c 400 "$TMP_ROOT/$label.out"))"
}

# step_output <label> <index>: the recorded tool output of one step.
step_output() {
  sed -n "$(($2 + 1))p" "$TMP_ROOT/$1.results" | jq -r .content
}

GIT_PATHS=$(fm_external_git_paths "$WORK" "$GATE") || fail "fm_external_git_paths could not resolve the guard's worktree"
CONTAINED=$(fm_external_settings_json 0 "127.0.0.1:$LISTED_PORT" \
  "$TMP_ROOT/granted"$'\n'"$(printf '%s\n' "$GIT_PATHS" | sed -n 's/^allow //p')" \
  "$SKILLS"$'\n'"$WORK/.claude/settings.json"$'\n'"$WORK/.claude/settings.local.json"$'\n'"$(printf '%s\n' "$GIT_PATHS" | sed -n 's/^deny //p')" \
  "" "$OWN_HOOK")
# shellcheck disable=SC2086  # FM_EXTERNAL_CLAUDE_FLAGS is a list of separate flags.
run_arm contained "$CONTAINED" $FM_EXTERNAL_CLAUDE_FLAGS
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
assert_not_contains "$(step_output contained 8)" "canary-gh-token" \
  "claude $CLAUDE_VERSION let the contained worker read the gh credential store"
assert_contains "$(step_output contained 9)" "skill-body" \
  "claude $CLAUDE_VERSION refused a read of the read-only --add-dir directory"
assert_not_contains "$(step_output contained 10)" "skills-written" \
  "claude $CLAUDE_VERSION let a shell command write the read-only --add-dir directory"
[ "$(cat "$SKILLS/SKILL.md")" = skill-body ] || fail "claude $CLAUDE_VERSION changed a file in the read-only --add-dir directory"
[ ! -e "$SKILLS/tool-file" ] || fail "claude $CLAUDE_VERSION let the Write tool write the read-only --add-dir directory"
assert_not_contains "$(step_output contained 12)" "settings-written" \
  "claude $CLAUDE_VERSION let a shell command write the working directory's .claude/settings.json"
[ "$(cat "$WORK/.claude/settings.json")" = "$PROJECT_HOOK" ] \
  || fail "claude $CLAUDE_VERSION let the contained worker rewrite the working directory's .claude/settings.json"
assert_not_contains "$(step_output contained 14)" "gate-hook-written" \
  "claude $CLAUDE_VERSION let the contained worker write a granted gate repository's hooks"
[ ! -e "$GATE/hooks/post-checkout" ] || fail "claude $CLAUDE_VERSION planted a hook in the granted gate repository"
assert_contains "$(step_output contained 15)" "gate-written" \
  "claude $CLAUDE_VERSION refused the rest of the granted gate repository, so the hooks check proves nothing"
assert_not_contains "$(step_output contained 16)" "canary-outside-value" \
  "claude $CLAUDE_VERSION let a shell command read a .env outside the working directory"
assert_not_contains "$(step_output contained 17)" "canary-outside-value" \
  "claude $CLAUDE_VERSION let the Read tool read a .env outside the working directory"
assert_contains "$(step_output contained 18)" "commit-ok" \
  "claude $CLAUDE_VERSION refused a commit in the linked worktree, so the narrowed git grants break delivery"
assert_contains "$(step_output contained 19)" "push-ok" \
  "claude $CLAUDE_VERSION refused a push to the local gate, so the narrowed gate grants break delivery"
[ "$(git -C "$GATE" rev-parse refs/heads/probe 2>/dev/null)" = "$(git -C "$WORK" rev-parse HEAD)" ] \
  || fail "the contained worker's push did not land its commit in the gate"
for step in 20:common-link-written 21:admin-link-written 22:admin-config-written 23:other-link-written 24:gate-link-written; do
  assert_not_contains "$(step_output contained "${step%%:*}")" "${step#*:}" \
    "claude $CLAUDE_VERSION let the contained worker write a git link or config file (${step#*:})"
done
[ ! -e "$COMMON/commondir" ] && [ ! -e "$ADMIN/config.worktree" ] && [ ! -e "$GATE/commondir" ] \
  || fail "claude $CLAUDE_VERSION created a git link or config file the sandbox must refuse"
[ "$(cat "$ADMIN/commondir")" = "../.." ] && [ "$(cat "$COMMON/worktrees/other/commondir")" = "../.." ] \
  || fail "claude $CLAUDE_VERSION rewrote a worktree's commondir link"
[ ! -e "$TMP_ROOT/project-hook-fired" ] || fail "claude $CLAUDE_VERSION ran a hook from the checkout's own .claude/settings.json"
[ -e "$TMP_ROOT/own-hook-fired" ] || fail "claude $CLAUDE_VERSION did not run the busy hook the --settings file carries"

CONTROL=$(printf '%s' "$CONTAINED" | jq -c 'del(.sandbox.network.strictAllowlist)')
run_arm control "$CONTROL" --strict-mcp-config
assert_contains "$(step_output control 1)" "reached-unlisted" \
  "claude $CLAUDE_VERSION closed the network without network.strictAllowlist, so this guard no longer proves that key is load-bearing; re-measure and update the guard"
[ -e "$TMP_ROOT/project-hook-fired" ] \
  || fail "claude $CLAUDE_VERSION ran no checkout hook even without --setting-sources user, so this guard no longer proves that flag is load-bearing; re-measure and update the guard"

pass "Claude Code $CLAUDE_VERSION: the external worker sandbox refuses .env anywhere, the gh store, unlisted hosts, outside writes, and writes to read-only grants and git links under bypass, still commits and pushes, runs no checkout hook, and network.strictAllowlist and --setting-sources user are what close the network and the project settings"
