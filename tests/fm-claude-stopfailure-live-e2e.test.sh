#!/usr/bin/env bash
# Live Claude regression for the StopFailure supervision recovery
# (bin/fm-claude-stopfailure.sh, docs/watcher-continuity.md "API-error turn
# ends").
# Proves, against the real installed Claude Code, the real tracked
# .claude/settings.json registration, and an interactive tmux session that is
# sent NO message after its first prompt:
#   1. recovery - the rewake handling turn of an actionable wake ends in an API
#      error; the StopFailure hook waits while the endpoint stays down, rewakes
#      the idle session once it answers, the resumed turn ends in a normal Stop,
#      and the Stop-owned auto-arm re-arms exactly once more with no alert;
#   2. alert - when the endpoint never answers, the captain is alerted through a
#      real config/wedge-alarm command channel within FM_GUARD_GRACE of the
#      failure, a typed downtime episode is published, nothing rewakes, and the
#      rate limit holds the alert to one.
# The API is a local stub (ANTHROPIC_BASE_URL), so the guard spends no model
# tokens: it is default-on wherever claude, tmux, and python3 are installed. The
# project, FM_HOME, config directory, and tmux server are isolated; no live fleet
# home, worktree, or session is touched.
# shellcheck disable=SC2016 # the lab scripts and hook commands are read by other shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_STOPFAILURE_LIVE_E2E claude tmux python3 jq git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
CLAUDE_VERSION=$(claude --version)

LABS=()
TMUX_DIRS=()
SERVER_PIDS=()
FIRST_HOMES=()

cleanup() {
  local i
  for i in "${!TMUX_DIRS[@]}"; do
    [ -z "${TMUX_DIRS[$i]}" ] || TMUX_TMPDIR="${TMUX_DIRS[$i]}" tmux kill-server 2>/dev/null || true
  done
  for i in "${!SERVER_PIDS[@]}"; do
    [ -z "${SERVER_PIDS[$i]}" ] || kill "${SERVER_PIDS[$i]}" 2>/dev/null || true
  done
  for i in "${!FIRST_HOMES[@]}"; do
    [ ! -d "${FIRST_HOMES[$i]}" ] || "$LAB_HOME_HELPER" teardown "${FIRST_HOMES[$i]}" 2>/dev/null || true
  done
  for i in "${!LABS[@]}"; do
    rm -rf "${LABS[$i]}"
  done
}
trap cleanup EXIT

# Stub Anthropic endpoint. State is files in the lab directory:
#   down            present while the "API" is down: a model request whose newest
#                   message is the rewake handling turn gets an API error, and a
#                   bare GET (the hook's reachability probe) gets a 503.
# Every model request is appended to requests.jsonl with its newest message text.
write_stub() {  # <lab>
  cat > "$1/stub.py" <<'PY'
import http.server, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
count = 0

def text_of(msg):
    c = msg.get('content', '')
    if isinstance(c, str):
        return c
    return '\n'.join(b.get('text', '') for b in c if isinstance(b, dict))

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype='application/json'):
        self.send_response(code); self.send_header('Content-Type', ctype); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        down = (root / 'down').exists()
        (root / 'probes.log').open('a').write('%f %s\n' % (time.time(), 'down' if down else 'up'))
        self._send(503 if down else 404, b'{}')
    do_HEAD = do_GET
    def do_POST(self):
        global count
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if 'count_tokens' in self.path or '/messages' not in self.path:
            return self._send(200, b'{"input_tokens":1}')
        count += 1
        msgs = body.get('messages', [])
        last = text_of(msgs[-1]) if msgs else ''
        fail = (root / 'down').exists() and 'needs a handling turn' in last
        with (root / 'requests.jsonl').open('a') as f:
            f.write(json.dumps({'n': count, 'at': time.time(), 'fail': fail,
                                'banner': 'the API answers again' in last, 'last': last[-300:]}) + '\n')
        if fail:
            return self._send(400, b'{"type":"error","error":{"type":"invalid_request_error","message":"LAB_API_DOWN"}}')
        text = 'LAB_OK'
        msg = {'id': 'msg_lab_%d' % count, 'type': 'message', 'role': 'assistant', 'model': body.get('model', 'lab'),
               'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
        events = [('message_start', {'type': 'message_start', 'message': msg}),
                  ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
                  ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}}),
                  ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
                  ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}}),
                  ('message_stop', {'type': 'message_stop'})]
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for ev, data in events:
            self.wfile.write(('event: %s\ndata: %s\n\n' % (ev, json.dumps(data))).encode()); self.wfile.flush()

srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
(root / 'port').write_text(str(srv.server_port))
srv.serve_forever()
PY
}

# wait_for <seconds> <command...>: poll until the command succeeds.
wait_for() {
  local limit=$1 waited=0
  shift
  until "$@"; do
    [ "$waited" -lt $((limit * 5)) ] || return 1
    sleep 0.2
    waited=$((waited + 1))
  done
}

# start_lab <name> <guard-grace>: build the isolated project, home, stub, and
# Claude session, then send nothing further. Sets LAB, HOME_DIR, SESSION,
# TMUX_DIR.
start_lab() {
  local name=$1 grace=$2 project config port
  LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-sf-live.XXXXXX")" && pwd -P)
  LABS+=("$LAB")
  project="$LAB/project"
  config="$LAB/config"
  HOME_DIR="$LAB/fmhome"
  SESSION="sf-$name"
  mkdir -p "$config" "$LAB/userhome"

  # The real tracked hooks and scripts, in a clone of this worktree.
  git clone -q "$ROOT" "$project"
  cp -R "$ROOT/bin/." "$project/bin/"
  cp "$ROOT/.claude/settings.json" "$project/.claude/settings.json"

  "$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null || fail "lab home was not created"
  FIRST_HOMES+=("$HOME_DIR")
  TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$HOME_DIR") || fail "lab tmux dir was not created"
  TMUX_DIRS+=("$TMUX_DIR")
  mkdir -p "$HOME_DIR/data"
  printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
  # A dead prior owner, as in the auto-arm live regression; the tracked
  # SessionStart hook reclaims it for this session.
  printf '9999999\n' > "$HOME_DIR/state/.lock"
  # Plain arm path (the host fixture below is the arm); the StopFailure hook is
  # independent of which engine armed the wake.
  : > "$HOME_DIR/config/supervision-host-off"
  # A real command channel: the alert is the line this command appends.
  printf 'command:cat >> "%s/alert.txt"\n' "$LAB" > "$HOME_DIR/config/wedge-alarm"

  # Arm fixture: run 1 closes actionable (the wake that creates the handling
  # turn); later runs close clean and end the in-flight need.
  cat > "$project/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# The hook's detached handling successor is not a foreground arm.
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  echo "successor pid=$$" >> "$FM_HOME/state/successor-ran"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 2 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-wake-%s\n' "$N"
exit 0
SH
  chmod +x "$project/bin/fm-watch-arm.sh"

  write_stub "$LAB"
  : > "$LAB/down"
  python3 "$LAB/stub.py" "$LAB" > "$LAB/stub.log" 2>&1 &
  SERVER_PIDS+=("$!")
  wait_for 10 test -s "$LAB/port" || fail "stub endpoint did not start: $(cat "$LAB/stub.log")"
  port=$(cat "$LAB/port")

  python3 - "$config" "$project" <<'PY'
import json, sys, pathlib
config, project = pathlib.Path(sys.argv[1]), sys.argv[2]
(config / '.claude.json').write_text(json.dumps({
    'hasCompletedOnboarding': True, 'theme': 'dark',
    'projects': {project: {'hasTrustDialogAccepted': True,
                           'hasClaudeMdExternalIncludesApproved': True,
                           'hasClaudeMdExternalIncludesWarningShown': True}},
    'customApiKeyResponses': {'approved': ['fm-isolated-lab'], 'rejected': []}}))
PY

  cat > "$LAB/launch.sh" <<SH
#!/usr/bin/env bash
cd '$project' || exit 1
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT ANTHROPIC_AUTH_TOKEN
export HOME='$LAB/userhome' CLAUDE_CONFIG_DIR='$config' FM_HOME='$HOME_DIR'
export ANTHROPIC_BASE_URL='http://127.0.0.1:$port' ANTHROPIC_API_KEY='fm-isolated-lab'
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false DISABLE_AUTOUPDATER=1
export FM_GUARD_GRACE='$grace' FM_STOPFAILURE_BACKOFF_BASE=2 FM_STOPFAILURE_BACKOFF_CAP=4
exec claude --model claude-sonnet-4-6 --effort low --permission-mode default --setting-sources project \\
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --system-prompt 'Reply briefly without tools.' \\
  'Reply LAB_OK.'
SH
  TMUX_TMPDIR="$TMUX_DIR" tmux new-session -d -s "$SESSION" -x 120 -y 40 "bash '$LAB/launch.sh'" \
    || fail "tmux session did not start"
}

failing_requests() { jq -s '[.[] | select(.fail)] | length' "$LAB/requests.jsonl" 2>/dev/null || echo 0; }
episode_present() { [ -e "$HOME_DIR/state/.claude-stopfailure-episode" ]; }
alert_present() { [ -s "$LAB/alert.txt" ]; }
pane_dump() { TMUX_TMPDIR="$TMUX_DIR" tmux capture-pane -pt "$SESSION" -S - 2>/dev/null | tail -30; }
diag() { printf 'pane:\n%s\nrequests:\n%s\nhandler log:\n%s\n' "$(pane_dump)" "$(cat "$LAB/requests.jsonl" 2>/dev/null | cut -c1-300)" "$(cat "$HOME_DIR/state/.claude-stopfailure.log" 2>/dev/null)"; }

# --- 1. recovery -------------------------------------------------------------------
start_lab recovery 300

# The first Stop fires the auto-arm, whose actionable close rewakes the idle
# session; that handling turn gets the stub's API error, so Claude runs
# StopFailure instead of Stop.
wait_for 90 episode_present || fail "StopFailure hook never recorded an episode (the API-error turn end did not reach it)
$(diag)"
[ "$(failing_requests)" -ge 1 ] || fail "the handling turn was never failed by the stub
$(diag)"
[ ! -e "$HOME_DIR/state/arm-ran" ] || [ "$(wc -l < "$HOME_DIR/state/arm-ran" | tr -d ' ')" = 1 ] \
  || fail "the auto-arm re-armed before the session recovered: $(cat "$HOME_DIR/state/arm-ran")"

# The session is idle and nobody types. Keep the endpoint down long enough that
# the hook has to wait, then bring it back.
sleep 6
grep -q down "$LAB/probes.log" 2>/dev/null || fail "the hook never probed the endpoint while it was down
$(diag)"
[ ! -s "$LAB/alert.txt" ] || fail "alerted inside the grace window"
rm -f "$LAB/down"

rewoken() { [ "$(jq -s '[.[] | select(.banner)] | length' "$LAB/requests.jsonl" 2>/dev/null)" = 1 ]; }
need_ended() { [ ! -e "$HOME_DIR/state/task.meta" ]; }
wait_for 90 rewoken \
  || fail "the idle session was not rewoken after the endpoint returned
$(diag)"
# The resumed turn ends in a normal Stop, whose auto-arm is the only re-arm path;
# the fixture arm ends the in-flight need on its first foreground run after that.
wait_for 60 need_ended \
  || fail "the resumed turn's Stop did not re-arm through the auto-arm
$(diag)"
ARMS_AFTER=$(wc -l < "$HOME_DIR/state/arm-ran" | tr -d ' ')
sleep 3
[ "$(wc -l < "$HOME_DIR/state/arm-ran" | tr -d ' ')" = "$ARMS_AFTER" ] || fail "arms kept running after recovery: $(cat "$HOME_DIR/state/arm-ran")"
[ "$ARMS_AFTER" -ge 2 ] || fail "the Stop-owned auto-arm never re-armed: $(cat "$HOME_DIR/state/arm-ran")"
[ ! -s "$LAB/alert.txt" ] || fail "a recovered episode alerted: $(cat "$LAB/alert.txt")"
[ ! -e "$HOME_DIR/state/.claude-stopfailure-episode" ] || fail "the clean Stop did not end the episode"
grep -q 'rewake: API reachable' "$HOME_DIR/state/.claude-stopfailure.log" || fail "hook log lacks the rewake decision"
# No later user message: the transcript holds exactly one genuine user prompt
# (the launch prompt); every other user-role entry is hook feedback.
human_prompts() {  # <lab>
  jq -s '[.[] | select(.type == "user" and (.isMeta | not))
         | (.message.content | if type == "string" then . else map(.text? // "") | join("") end)
         | select(test("Stop hook|SYSTEM NOTIFICATION|system-reminder") | not)] | length' \
    "$1"/config/projects/*/*.jsonl
}
[ "$(human_prompts "$LAB")" = 1 ] || fail "the session received a user message beyond its launch prompt: $(human_prompts "$LAB")"
TMUX_TMPDIR="$TMUX_DIR" tmux kill-server 2>/dev/null || true
printf 'ok - Claude %s live E2E: an API-error handling turn rewoke after the endpoint returned, re-armed once, and never alerted\n' "$CLAUDE_VERSION"

# --- 2. alert -----------------------------------------------------------------------
start_lab alert 12

wait_for 90 episode_present || fail "StopFailure hook never recorded an episode in the alert run
$(diag)"
FAILED_AT=$(date +%s)
wait_for 60 alert_present || fail "the captain was not alerted for an unrecoverable API error
$(diag)"
ALERT_DELAY=$(( $(date +%s) - FAILED_AT ))
[ "$ALERT_DELAY" -le 30 ] || fail "alert took ${ALERT_DELAY}s, past FM_GUARD_GRACE plus slack"
grep -q 'supervision is OFF' "$LAB/alert.txt" || fail "alert lacks the supervision-off summary: $(cat "$LAB/alert.txt")"
case "$(cat "$HOME_DIR/state/.watcher-down" 2>/dev/null)" in
  pending:downtime:*|announced:downtime:*) ;;
  *) fail "no typed downtime episode after the alert: $(cat "$HOME_DIR/state/.watcher-down" 2>/dev/null)" ;;
esac
sleep 12
[ "$(wc -l < "$LAB/alert.txt" | tr -d ' ')" = 1 ] || fail "alert was not rate limited: $(cat "$LAB/alert.txt")"
[ "$(jq -s '[.[] | select(.banner)] | length' "$LAB/requests.jsonl")" = 0 ] || fail "rewoke while the endpoint was down"
[ "$(wc -l < "$HOME_DIR/state/arm-ran" | tr -d ' ')" = 1 ] || fail "arms ran with the session down: $(cat "$HOME_DIR/state/arm-ran")"
printf 'ok - Claude %s live E2E: an unrecoverable API error alerted through a real command channel within the guard grace, once, with a typed downtime episode and no rewake\n' "$CLAUDE_VERSION"
